{ config, lib, pkgs, ...} :

with lib;

let
  cfg = config.services.s6-init;
  dump = import ./dump.nix;

in {
  options = {
    services.s6-init = {
      enable = mkEnableOption "s6-init";

      serviceDir = mkOption rec {
        type = types.str;
        description = ''
          Directory where the system services are defined.
          Place it at a filesystem that is available at stage-2-init.
          (etc?, run?)
        '';
        example = default;
        default = "/run/s6/services";
      };
      
      scanDir = mkOption rec {
        type = types.str;
        description = ''
          Directory where the system services are managed.
          Place it at a filesystem that is available at stage-2-init.
          Gets created at end of stage-2-init
        '';
        example = default;
        default = "/run/s6/scan";
      };

      lifeDir = mkOption rec {
        type = types.str;
        description = ''
          Directory where the system services are managed.
          Place it at a filesystem that is available at stage-2-init.
          Gets created at end of stage-2-init
        '';
        example = default;
        default = "/run/s6-rc";
      };
      
      fifo = mkOption rec {
        type = types.str;
        description = ''
          Location of the named pipe that copies logs from s6-svscan to the logger.
        '';
        example = default;
        default = "/run/s6/logger-fifo";
      };
      
      syslogDir = mkOption rec {
        type = types.str;
        description = "Directory where the logs are written. Everything gets logged here that does not get logged elsewhere";
        example = default;
        default = "/var/log/s6/syslog";
      };
    };
  };
  
  config = mkIf cfg.enable (
    let
    
      s6-init = pkgs.writeScript "s6-init"
    
      (let 
          scanner = pkgs.writeScript "system-svscan" ''
            #!${pkgs.execline}/bin/execlineb -P
    
            ${pkgs.execline}/bin/exec -c                                     # clear environment
            #${pkgs.s6}/bin/s6-envdir -I /service/.s6-svscan/env              # read env (optional)
            ${pkgs.s6}/bin/s6-setsid -qb
            ${pkgs.execline}/bin/redirfd -r 0 /dev/null                      # close stdin
            ${pkgs.execline}/bin/redirfd -wnb 1 ${cfg.fifo}                  # redirect stdout to fifo
            ${pkgs.execline}/bin/fdmove -c 2 1                               # redirect stderr to fifo
            ${pkgs.execline}/bin/exec -a s6-svscan                           # name it 's6-svscan' instead of /nix/store/...
            ${pkgs.s6}/bin/s6-svscan -t0 ${cfg.scanDir}                      # run it 
            # (this never exits)
          '';

          logger-service = "syslog-logger-service";
          logger-serviceDir = "${cfg.serviceDir}/${logger-service}";
          logger = pkgs.writeScript "syslog-logger" ''
            #!${pkgs.execline}/bin/execlineb -P

            # TODO: change user to something less root-y
            ${pkgs.execline}/bin/redirfd -r 0 ${cfg.fifo}                  # open fifo and pass it as stdin to s6-log
            ${pkgs.execline}/bin/exec -a s6-log                            # name it 's6-log' instead of /nix/store/...
            ${pkgs.s6}/bin/s6-log -v -b -l 1024 T n30 s10000000 ${cfg.syslogDir}
          '';

          date-service = "date-service";
          date-serviceDir = "${cfg.serviceDir}/${date-service}";
          date-run = pkgs.writeScript "${date-service}-run" ''
            #!/bin/sh
            
            while ${pkgs.coreutils}/bin/sleep 5 ; do ${pkgs.coreutils}/bin/date | \
                  ${pkgs.coreutils}/bin/tee -a /var/log/date-log; done
          '';
 
          getty-service = "getty-service";
          getty-serviceDir = "${cfg.serviceDir}/${getty-service}";
          getty-run = pkgs.writeScript "gettyd" ''
            #!/bin/sh
            
            ${pkgs.utillinux}/bin/agetty -a root tty8
          '';

          
      in
        ''
          set -x
          echo Starting s6-init ...
          # Create a s6-service scan proces that can start its own logger
          PATH=${pkgs.coreutils}/bin
          mkdir -p ${cfg.serviceDir}
          mkdir -p ${cfg.scanDir}
      
          # Make the logger service
          mkdir -p ${logger-serviceDir}
          cp ${logger} ${logger-serviceDir}/run
          echo "longrun" > ${logger-serviceDir}/type

          # Make the log directory and fifo
          mkdir -p ${cfg.syslogDir}
          mkfifo ${cfg.fifo}

          ## Make a date-service
          mkdir -p ${date-serviceDir}
          cp ${dated} ${date-serviceDir}/run
          echo "longrun" > ${date-serviceDir}/type
          
          ## Make a getty-service
          mkdir -p ${getty-serviceDir}
          cp ${gettyd} ${getty-serviceDir}/run
          echo "longrun" > ${getty-serviceDir}/type

          # create the initial 'compiled' directory
          # s6-rc-compile does not like it when the directory exists, so use mktemp -u unsafe
          CompiledDir=`mktemp -d -u "/tmp/rc6-compiled-XXXXXX"`
          ${pkgs.s6-rc}/bin/s6-rc-compile -v 2 "$CompiledDir" "${cfg.serviceDir}"


          # delete the 'down' markers, so svscan will start them up.
          #${pkgs.findutils}/bin/find ${cfg.scanDir} -name 'down' -delete

          # start the services
          ( 
             sleep 2; 
             # initialize the live service environment
             ${pkgs.s6-rc}/bin/s6-rc-init -c "$CompiledDir" -l "${cfg.lifeDir}" "${cfg.scanDir}"

             # TODO: add 'all-bundle'
             ${pkgs.s6-rc}/bin/s6-rc -v 2 -l "${cfg.lifeDir}" change "${logger-service}" "${date-service}" "${getty-service}"
          ) &
               
          # Run the svscan service in the background
          echo Starting s6-svscan on ${cfg.scanDir}
          ${scanner}

          # Keep running until shutdown.
          # The end

          # From here we always have logging
          echo "foo bar baz"
          echo "baz bar foo" >&2
      

        '');
    in {

      # set to "$s6-init" to start with S6 instead of systemd!
      boot.systemdExecutable = "${s6-init}";
    
      boot.postBootCommands =
        #''
        #  #  ${s6-init} &
        #'';
        builtins.trace (builtins.attrNames config.systemd.services) "";
            
      #system.activationScripts = {
        #  s6-svsan = {
          #    deps = [];
          #    text = XYZZY
          #
          #
          #  };
          #};
    
      # The group name that all s6-logs run under.
      users.groups."s6" = {};
    }
  );
    
  meta = {
    maintainers = "guido";
    # doc = ./doc.xml; # docbook (zee https://nixos.org/manual/nixos/stable/index.html#sec-writing-modules 50.5 meta attributes)
  };
}

