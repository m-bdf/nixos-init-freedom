{ config, lib, pkgs, ...} :

with lib;
with builtins;

let
  cfg = config.services.s6-init;

  dump = import ./dump.nix;
  dumpit = x: trace (dump x) x;

  systemd = import ./systemd.nix { pkgs =  pkgs; };


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

          logger-service = rec {
            name = "syslog-logger-service";
            type = "longrun";
            run = ''
              #!${pkgs.execline}/bin/execlineb -P

              # TODO: change user to something less root-y
              ${pkgs.execline}/bin/redirfd -r 0 ${cfg.fifo}                  # open fifo and pass it as stdin to s6-log
              ${pkgs.execline}/bin/exec -a s6-log                            # name it 's6-log' instead of /nix/store/...
              ${pkgs.s6}/bin/s6-log -v -b -l 1024 T n30 s10000000 ${cfg.syslogDir}
            '';
          };

          date-service =  rec {
            name = "date-service";
            type = "longrun";
            run = ''
              #!/bin/sh

              while ${pkgs.coreutils}/bin/sleep 5 ; do ${pkgs.coreutils}/bin/date ; done
            '';
          };

          log-tailer = rec {
            name = "log-tailer";
            type = "longrun";
            run = ''
              #!/bin/sh

              ${pkgs.s6}/bin/s6-setsid \
              ${pkgs.execline}/bin/exec -a log-tail \
              ${pkgs.utillinux}/bin/agetty -a root -l ${pkgs.coreutils}/bin/tail -o '-F /var/log/s6/syslog/current' tty2 linux
            '';
          };

          getty-service = rec {
            name = "getty-service";
            type = "longrun";
            run = ''
              #!/bin/sh

              ${pkgs.s6}/bin/s6-setsid \
              ${pkgs.utillinux}/bin/agetty -a root tty8 linux
            '';
          };

          nix-daemon = rec {
            name = "nix-daemon";
            type = "longrun";
            run = ''
              #!${pkgs.execline}/bin/execlineb -P

              ${pkgs.execline}/bin/exec -c                                     # clear environment
              #${pkgs.s6}/bin/s6-envdir -I /service/.s6-svscan/env              # read env (optional)
              ${pkgs.s6}/bin/s6-setsid -qb
              ${pkgs.execline}/bin/exec -a nix-daemon                          # name it 'nix-daemon' instead of /nix/store/...
              ${pkgs.nix}/bin/nix-daemon --daemon
            '';
          };

          #console-getty = systemd.convert-service "console-getty" config.systemd.services.console-getty;
          #haveged = systemd.convert-service "haveged" config.systemd.services.haveged;

          # convert the specified services into s6-services
          #systemd-imports = [ "console-getty" "haveged" "unbound" "sshd" "network-setup" ];
          systemd-imports = [                                             "network-setup" ];
          systemd-rejects =
            [ "dbus" "nix-daemon" "polkit" "systemd-backlight@" "systemd-fsck@"
              "halt.target" "shutdown.target" "sleep.target"
            ];
          systemd-services = map (svc-name: systemd.convert-service svc-name config.systemd.services.${svc-name})
            (filter (svc-name:   elem svc-name systemd-imports)
            (filter (svc-name: ! elem svc-name systemd-rejects) (attrNames config.systemd.services
            )
            ));

            startup-services = [ logger-service log-tailer date-service getty-service ] ++
            #(trace (dump systemd-services)
            systemd-services
            #)
            ;

          make-service = svc:
            if svc.type == "longrun" then
              make-longrun svc
            else make-oneshot svc;

          make-oneshot = svc:
          let
            dir = "${cfg.serviceDir}/${svc.name}";
          in
          ''
            # Make oneshot ${svc.name}
            mkdir -p ${dir}
            cat << 'EOF-XYZZY' > ${dir}/up
            ${svc.up}
            EOF-XYZZY
            chmod +x ${dir}/up
            echo ${svc.type} > ${dir}/type
          '';

          make-longrun = svc:
          let
            dir = "${cfg.serviceDir}/${svc.name}";
          in
          ''
            # Make service ${svc.name}
            mkdir -p ${dir}
            cat << 'EOF-XYZZY' > ${dir}/run
            ${svc.run}
            EOF-XYZZY
            chmod +x ${dir}/run
            echo ${svc.type} > ${dir}/type
          '' +
          # add a finish script
          (if hasAttr "finish" svc then
          ''
            cat << 'EOF-XYZZY' > ${dir}/finish
            ${svc.finish}
            EOF-XYZZY
          ''
          else "");

          make-services = servs:
          builtins.concatStringsSep "\n" (builtins.map make-service servs);

      in
        ''
          #!/bin/sh
          set -x
          echo Starting s6-init ...
          # Create a s6-service scan process that can start its own logger
          PATH=${pkgs.coreutils}/bin
          mkdir -p ${cfg.serviceDir}
          mkdir -p ${cfg.scanDir}


          # Make the log directory and fifo
          mkdir -p ${cfg.syslogDir}
          mkfifo ${cfg.fifo}

        '' +
        (make-services startup-services)
        + ''
          # create the initial 'compiled' directory
          # s6-rc-compile does not like it when the directory exists, so use mktemp -u unsafe
          CompiledDir=`mktemp -d -u "/tmp/rc6-compiled-XXXXXX"`
          ${pkgs.s6-rc}/bin/s6-rc-compile -v 2 "$CompiledDir" "${cfg.serviceDir}"

          # start the services
          (
             sleep 2;
             # initialize the live service environment
             ${pkgs.s6-rc}/bin/s6-rc-init -c "$CompiledDir" -l "${cfg.lifeDir}" "${cfg.scanDir}"

             # TODO: add 'all-bundle'
             ${pkgs.s6-rc}/bin/s6-rc -v 2 -l "${cfg.lifeDir}" change ${concatStringsSep " " (map (x: x.name) startup-services)}
          ) &

          # Run the svscan service in the background
          echo Starting s6-svscan on ${cfg.scanDir}
          exec ${scanner}

          # Keep running until shutdown.
          # The end

        '');
    in {

      # set to "$s6-init" to start with S6 instead of systemd!
      boot.systemdExecutable = "${s6-init}";

      boot.postBootCommands =
        #(trace (dump( config.systemd.services.unbound.preStart))
        ""
        #)
        ;

      # The group name that all s6-logs run under.
      users.groups."s6" = {};
    }
  );

  meta = {
    maintainers = "guido";
    # doc = ./doc.xml; # docbook (zee https://nixos.org/manual/nixos/stable/index.html#sec-writing-modules 50.5 meta attributes)
  };
}
