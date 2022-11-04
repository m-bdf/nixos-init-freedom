{
  description = "Init-Freedom on NixOS using S6";

  outputs = { self }: {
    nixosModules.s6-init = import ./s6-init.nix;
  };
}
