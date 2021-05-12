{ config, lib, pkgs, ...} :

with lib;
with builtins;

let
  cfg = config.services.s6-init;

  dump = import ./dump.nix;
  dumpit = x: trace (dump x) x;
  dumplabel = l: x: trace (dump [ l x ]) x;

  systemd = import ./systemd.nix { pkgs =  pkgs; lib = lib; };


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
            name = "logger-service";
            type = "longrun";
            run = ''
              #!${pkgs.execline}/bin/execlineb -P

              # TODO: change user to something less root-y
              ${pkgs.execline}/bin/redirfd -r 0 ${cfg.fifo}                  # open fifo and pass it as stdin to s6-log
              ${pkgs.execline}/bin/exec -a s6-log                            # name it 's6-log' instead of /nix/store/...
              ${pkgs.s6}/bin/s6-log -v -b -l 1024 T n30 s10000000 ${cfg.syslogDir}
            '';
          };

          log-tailer = rec {
            name = "log-tailer";
            type = "longrun";
            dependencies = [ "logger-service" ];
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
            dependencies = []; # don't depend on anything, it's a backup entry into the system.
            run = ''
              #!/bin/sh

              ${pkgs.s6}/bin/s6-setsid \
              ${pkgs.utillinux}/bin/agetty -a root tty8 linux
            '';
          };

          nix-daemon = rec {
            name = "nix-daemon";
            type = "longrun";
            dependencies = [ "logger-service" ];
            run = ''
              #!${pkgs.execline}/bin/execlineb -P

              ${pkgs.execline}/bin/exec -c                                     # clear environment
              #${pkgs.s6}/bin/s6-envdir -I /service/.s6-svscan/env              # read env (optional)
              ${pkgs.s6}/bin/s6-setsid -qb
              ${pkgs.execline}/bin/exec -a nix-daemon                          # name it 'nix-daemon' instead of /nix/store/...
              ${pkgs.nix}/bin/nix-daemon --daemon
            '';
          };

          network-target = rec {
            name = "network.target";
            type = "oneshot";
            dependencies = [ "logger-service" ];
            up = ''
              #!${pkgs.execline}/bin/execlineb -P

              foreground { ${pkgs.iproute}/bin/ip address add 127.0.0.1 dev lo }
              foreground { ${pkgs.iproute}/bin/ip link set lo up }

              # address is set by network-...eth0
              foreground { ${pkgs.iproute}/bin/ip link set eth0 up }
            '';
            down = ''
              #!${pkgs.execline}/bin/execlineb -P

              foreground { ${pkgs.iproute}/bin/ip link set eth0 down }
              foreground { ${pkgs.iproute}/bin/ip link set lo down }
            '';
          };

          # failing-oneshot = rec {
          #   name = "failing-oneshot";
          #   type = "oneshot";
          #   dependencies = [ "logger-service" ];
          #   up = ''
          #     #!${pkgs.execline}/bin/execlineb -P
          #
          #     foreground { ${pkgs.coreutils}/bin/echo "Failing oneshot fails" }
          #
          #     exit 100
          #   '';
          # };

          # failing-service = rec {
          #   name = "failing-service";
          #   type = "longrun";
          #   dependencies = [ "logger-service" "failing-oneshot" ];
          #   run = ''
          #     #!${pkgs.execline}/bin/execlineb -P
          #
          #     foreground { ${pkgs.coreutils}/bin/echo "Expect not to get started due to failing-oneshot" }
          #     ${pkgs.coreutils}/bin/sleep 123456
          #   '';
          # };

          # Reject these systemd-defined services. These create too much trouble.
          # Feel free to create s6 replacements using the same names and add these to `startup-services`
          systemd-rejects = concatStringsSep "|"
            [ "dbus" "polkit" "nscd"
              "nix-daemon" "nix-gc" "nix-optimise"
              "systemd-.*"
              "serial-getty@" "container-getty@" "getty@"
              "qemu-guest-agent" "prepare-kexec" "save-hwclock"
              "pre-sleep" "post-resume"
              "halt.target" "shutdown.target" "sleep.target"
              "container@"  # reject `container@` but accept `container@some-service`
              "zpool-trim"
            ];

          # Filter out the ones we don't want, keep the ones that are well behaved.
          systemd-services = map (svc-name: systemd.convert-service svc-name config.systemd.services.${svc-name})
            # filter out explicit rejected services ...
            # note builtins.match returns [] on match, null on no match
            (filter (svc-name: (match systemd-rejects svc-name) == null)

            # filter out empty serviceConfig ...
            (filter (svc-name: config.systemd.services.${svc-name}.serviceConfig != {})

            # ... from these services
              (attrNames config.systemd.services)
             ));

          # Use these services at startup.
          startup-services = [
            logger-service log-tailer getty-service nix-daemon
            network-target # sets up lo and eth0
          ] ++ systemd-services;

          # Missing dependencies are services specified in service dependencies but are not defined in `startup-services`.
          missing-dependencies =
            let
              all-deps = concatLists (map (svc: if hasAttr "dependencies" svc then svc.dependencies else []) startup-services);
              sort-deps = sort (a: b: a < b) all-deps;
              uniq-deps = lib.lists.unique sort-deps;
            in
            filter (x: ! elem x (map (s: s.name) startup-services)) uniq-deps;

          # Create a oneshot service with empty `up` and `down` scripts to satisfy the missing depencencies.
          # If you need other behaviour, create a service and add it to `startup-services`.
          make-missing-dependency = missing:
          {
            name = missing;
            type = "oneshot";
            up = ''
              #!/bin/sh

              exit 0
            '';
            down = ''
              #!/bin/sh

              exit 0
            '';
          };

          make-dependencies = svc: dir:
            if hasAttr "dependencies" svc && svc.dependencies != [] then ''
              cat << 'EOF-XYZZY' > "${dir}/dependencies"
              ${concatStringsSep "\n" svc.dependencies}
              EOF-XYZZY
            ''
            else "";

          make-service = svc:
          let
            s = dumplabel "make-service" svc;
            #dir = (trace (dump ["attrnames" (attrNames s)]) "${cfg.serviceDir}/${s.name}");
            #dir = "${cfg.serviceDir}/${s.name}";
            dir = "${cfg.serviceDir}/${s.name}";

          in
            if svc.type == "longrun" then
              make-longrun svc dir
            else make-oneshot svc dir;

          make-oneshot = svc: dir:
          ''
            # Make oneshot ${svc.name}
            mkdir -p ${dir}
            cat << 'EOF-XYZZY' > ${dir}/up
            ${svc.up}
            EOF-XYZZY
            chmod +x ${dir}/up
            echo ${svc.type} > ${dir}/type
          ''
          +
          # add `down` script
          (if hasAttr "down" svc then ''
            cat << 'EOF-XYZZY' > ${dir}/down
            ${svc.down}
            EOF-XYZZY
            chmod +x ${dir}/down
        '' else "")
          +
          # add dependencies
          (make-dependencies svc dir);


          make-longrun = svc: dir:
          ''
            # Make service ${svc.name}
            mkdir -p ${dir}
            cat << 'EOF-XYZZY' > ${dir}/run
            ${svc.run}
            EOF-XYZZY
            chmod +x ${dir}/run
            echo ${svc.type} > ${dir}/type
          ''
          +
          # add dependencies
          (make-dependencies svc dir)
          +
          # add a finish script
          (if hasAttr "finish" svc then
          ''
            cat << 'EOF-XYZZY' > ${dir}/finish
            ${svc.finish}
            EOF-XYZZY
          ''
          else "");

          # make-environment = svc dir:
          # (if hasAttr "environment" svc then
          # (concatStringsSep ""
          # (map (key: ''
          #   export ${key}
          #   ${key}=${svc.environment.${key}}
          # '') (attrNames svc.environment)))
          # else ''
          #   # Use a simple default path. Don't export.
          #   PATH=${pkgs.coreutils}/bin:
          # '');

          make-services = servs:
          builtins.concatStringsSep "\n"
          (builtins.map make-service (servs ++ map make-missing-dependency (dumplabel "missing-dependencies" missing-dependencies)));

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
