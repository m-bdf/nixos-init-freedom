# Functions to convert a systemd service unit to a s6 service definition
# ----------------------------------------------------------------------
{pkgs, ... }:

with builtins;

rec {
  convert-service-type = type:
  if elem type [ "simple" ] # TODO: add other types
    then "longrun"
    else throw ("cannot process systemd sevice of type [" + type +"]");


  convert-service-executable-prefixes = name: svc:
  let
    # TODO: handle multiple lines. Note, these might have their own prefixes. Arrrgh.
    text = if isString svc.serviceConfig.ExecStart
    then svc.serviceConfig.ExecStart
    else elemAt (svc.serviceConfig.ExecStart) 1; # ignore empty first line...
    first = substring 0 1 text;
    special = elem first [ "@"  "-"  ":"  "+"  "!" ];
    rest = if special
      then substring 1 ((stringLength text) -1) text
      else text;
    list = filter isString (split " +" rest); # split on spaces and filter out the spaces in between the strings
  in
  if special && first == "@"
    then {
      run = ''
        #!/bin/sh -e
        ${concatStringsSep " " ([ (elemAt list 0) ] ++ (tail (tail list)))}
      '';
      ps-name = elemAt list 1;
    }
    else {
      # no special prefix found. Use text as is.
      run = ''
        #!/bin/sh -e
        ${text}
      '';
    };


  convert-service = name: svc:
  {
    name = name;
    #type = convert-service-type svc;
    type = "longrun";
  }
  //
  # the executable text can start with a 'special prefix'.
  # It can lead to multiple attributes, eg run, ps-name, etc
  convert-service-executable-prefixes name svc;

}
