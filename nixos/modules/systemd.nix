# Functions to convert a systemd service unit to a s6 service definition
# ----------------------------------------------------------------------
{pkgs, ... }:

with builtins;

let
  dump = import ./dump.nix;
in

rec {

  make-type = name: svc:
  let
    Type = if hasAttr "Type" svc then svc.Type else                     # take Type if it specfied
           if hasAttr "BusName" svc then "dbus" else                    # when there is no BusName ...
           if hasAttr "ExecStart" svc.serviceConfig then "simple" else  # ... default to simple when ExecStart present
           "oneshot"; # default when neither Type nor Execstart are specified (and neither BusName)
  in
  if elem Type [ "simple" "exec" "forking" ] # TODO: add other types
  then
  {
    inherit Type;      # keep for later to detemine other flags
    type =  "longrun"; # s6-type
  }
  else throw ("cannot process systemd sevice of type [${Type}] for [${name}]");


  # The executable text can start with a 'special prefix'.
  # It can lead to multiple attributes, eg 'start', 'ps-name', etc
  make-start = name: svc:
  let
    # TODO: handle multiple lines. Note, these might have their own prefixes. Arrrgh.
    text = if isString svc.serviceConfig.ExecStart
    then svc.serviceConfig.ExecStart
    else elemAt (svc.serviceConfig.ExecStart) 1; # ignore empty first line...
    first = substring 0 1 text;
    special = elem first [ "@"  "-"  ":"  "+"  "!" ];
    rest = if special
      then substring 1 ((stringLength text) -1) text   # strip that first char off
      else text;
    list = filter isString (split " +" rest); # split on spaces and filter out the spaces in between the strings
  in
  if special && first == "@"
  then {
    # start is the zeroth and second up to last elements of the ExecStart
    start = concatStringsSep " " ([ (elemAt list 0) ] ++ (tail (tail list)));
    ps-name = elemAt list 1;  # the first element is the name in the process list
  }
  else {
    # no special prefix found. Use text as is.
    start = text;
  };


  make-prestart = name: svc:
  # if there is a preStart, create a dependency on it
  (if hasAttr "preStart" svc then { preStart = svc.preStart; } else {});

  # make-prestart = name: svc:
  # # If there is a preStart, create a new one-shot service to set it up
  # {
  #   name = "${name}-prestart";
  #   type = "oneshot";
  #   start =
  #     ''
  #       #!/bin/sh -e

  #       ${svc.preStart}
  #     '';
  # };


  # Convert a systemd service definition into one or more s6-services.
  # We split the preStart into a separate
  convert-service = name: svc:
  let serv =
    make-type     name svc //
    make-start    name svc //
    make-prestart name svc //
    #make-finish   name svc //
    {};
  in
  # only longrun for now
  {
    name = trace (dump serv) name;
    type = serv.type;
    run = ''
      #!/bin/sh

      # don't export
      PATH=${pkgs.coreutils}/bin:

      # PreStart
      ${if hasAttr "preStart" serv then serv.preStart else ""}

      # ExecStart
      exec ${serv.start}
    '';
    # TODO: ps-name:  ${if hasAttr "ps-name" then "${pkgs.execline}/bin/exec -a ${serv.ps-name}"}
  };
}
