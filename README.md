This is a fork of https://sr.ht/~guido/nixos-init-freedom
with added flake support.

# Nixos Init Freedom

This repository provides the code to create a NixOS system
without systemd as PID 1.

Instead it uses Skarnet's S6 init system.


# How to use

In your `flake.nix` add this repo as an input,
and import the provided `s6-init` module:

```nix
{
  inputs = {
    init-freedom.url = "github:m-bdf/nixos-init-freedom";
  };

  outputs = { self, nixpkgs, init-freedom }: {
    nixosConfigurations."<hostname>" =
      nixpkgs.lib.nixosSystem {
        modules = [
          init-freedom.nixosModules.s6-init # here
          ./configuration.nix
        ];
      };
  };
}
```

Then enable it in your `configuration.nix`:

```nix
{
  # Get me a decent init system!
  services.s6-init.enable = true;
}
```

## Test it

Build and run your NixOS system in a virtual machine:

```
nixos-rebuild build-vm --flake .#<hostname>
./result/bin/run-nixos-vm
```

Then from within the VM:

```sh
ps ax | head # see who is running as PID 1
```


# Why

Why?

1. Because I can

2. Because I like the power of Nix(OS)

3. Because I dislike the way systemd operates



# How it works

Actually, getting rid of systemd as PID 1 is easy,
NixOS has a hook at the end of the shell script that starts the system.

In `s6-init.nix` I set `boot.systemdExecutable = "${s6-init}"`.
This script starts `s6-svscan` after setting up the following services:

- `s6-log` to capture all logging to `/var/log/s6/syslog/current`

- `tail -F` on tty2

- `getty` on tty8 (autologin, so no passwords needed)

- `nix-daemon` (not tested)

- a one-shot script to enable lo and eth0 interface (hardcoded)

- the system specified services such as `unbound` and `sshd`

## systemd services

The goal is have freedom from systemd
but keep all the work that has already been done.

As such, the `systemd.nix` file contains the logic
to create a s6-service definition from the global config variable.
_That's the power of NixOS,
I don't have to parse the `/etc/systemd/system/<service>` files :-)_

For now I've tested it with `unbound` and `sshd`,
other services may work too.

To make these work I create 'empty' one-shot services
that just do `exit 0` for each missing dependency.
