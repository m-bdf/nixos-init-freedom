# Functions to convert a systemd service unit to a s6 service definition
# ----------------------------------------------------------------------
{pkgs, lib, ... }:

with builtins;

let
  dump = import ./dump.nix;
  dumpit = x : trace (dump x) x;
  dumplabel = l: x: trace (dump [ l x ]) x;

  # utils
  fetch = attr: svc: default: if hasAttr attr svc then svc.${attr} else default;

  # mapSL: iterate a function over a list where the list can be an atom
  # mapSL (x: x+2) [ 1 2 ] -> [ 3 4 ]
  # mapSL (x: x+2) 3       -> [ 5 ]
  mapSL = f: l:
  if isList l
  then map f l
  else [ (f l) ];

in

rec {

  fetch-type = name: svc:
  let
    Type = if hasAttr "Type" svc.serviceConfig then svc.serviceConfig.Type else # take Type if it specfied
           if hasAttr "BusName" svc then "dbus" else                            # check for dbus busnames
           if hasAttr "ExecStart" svc.serviceConfig then "simple" else          # default to simple when ExecStart present
           "oneshot"; # default when neither Type nor Execstart are specified (and neither BusName)
  in
  if elem Type [ "simple" "exec" "forking" "notify" ]
  then
  {
    inherit Type;      # keep for later to detemine other flags
    type =  "longrun"; # s6-type
  }
  else (if elem Type [ "oneshot" ]
  then
  {
    inherit Type;
    type = "oneshot";
  }
  else throw (trace (dump svc.serviceConfig) "cannot process systemd sevice of type [${Type}] for [${name}]")
  )
  ;

  # The executable text can start with a 'special prefix'.
  # It can lead to multiple attributes, eg 'start', 'ps-name', etc
  fetch-start = name: svc:
  if ! hasAttr "ExecStart" svc.serviceConfig then
  throw "Cannot process [${name}], no [ExecStart] present"
  else
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


  fetch-prestart = name: svc:
  (if hasAttr "preStart" svc then { preStart = svc.preStart; } else {});

  fetch-finish = name: svc:
  # if there is an ExecPostStop command, capture that.
  # TODO: filter special characters
  # TODO: fetch other ExecStop commands too
  (if hasAttr "ExecStopPost" svc.serviceConfig then { finish = svc.serviceConfig.ExecStopPost; } else {});

  fetch-env = name: svc:
  (if hasAttr "environment" svc then { environment = svc.environment; } else {});

  fetch-dependencies = name: svc:
  let
    fetch = attr: if hasAttr attr svc then svc.${attr} else [];
  in
  {
    wants = fetch "wants";
    requires = fetch "requires";
    requisite = fetch "requisite";
    binds-to = fetch "bindsTo";
    part-of = fetch "partOf";
    conflicts = fetch "conflicts";
    before = fetch "before";
    after = fetch "after";
    required-by = fetch "requiredBy";
  };

  # Convert a systemd service definition into one or more s6-services.
  convert-service = name: svc:
  let
    serv =
    (fetch-type     name svc) //
    (fetch-env      name svc) //
    (fetch-prestart name svc) //
    (fetch-start    name svc) //
    (fetch-finish   name svc) //
    (fetch-dependencies name svc) //
    {systemd = svc; };
  in
  if serv.type == "longrun" then make-longrun name serv
  else if serv.type == "oneshot" then make-oneshot name serv
  else throw "cannot create service for type [${serv.type}/${serv.Type}]";

  make-oneshot = name: serv:
  {
    name = "${name}.service";
    type = serv.type;
    dependencies = make-dependencies name serv;
    up = ''
      #!/bin/sh

      # Environment
      ${make-environment serv}

      # ExecStart
      exec ${serv.start}
    '';

    # TODO: make down based on ExecStop... tags.
    #down = ''
    #  #!/bin/sh
    #
    #  exit 0
    #'';
  };

  make-longrun = name: serv:
  let
    svc = trace (dump (attrNames serv.systemd.serviceConfig)) serv.systemd.serviceConfig;
    user = fetch "User" svc "";
    group = fetch "Group" svc ""; # not needed to change user?
    change-user = if user != "" then "${pkgs.s6}/bin/s6-setuidgid ${user} " else "";
  in
  {
    name = "${name}.service";
    type = serv.type;
    dependencies = make-dependencies name serv;
    run = ''
      #!/bin/sh

      # Environment
      ${make-environment serv}

      # make /run and /var/lib directories
      ${make-directories serv}

    ''
    +
    # PreStart
    (if hasAttr "preStart" serv then
    ''
      # PreStart
      ${change-user} ${serv.preStart}
    ''
    else "") +

    # ExecStart
    # TODO: ps-name:  ${if hasAttr "ps-name" then "${pkgs.execline}/bin/exec -a ${serv.ps-name}"}
    ''
      # ExecStart
      exec ${pkgs.s6}/bin/s6-setsid -qb ${change-user} ${serv.start}
    '';
  } //

  # add the finish script
  (if hasAttr "finish" serv then
  {
    finish = ''
      #!/bin/sh

      # TODO: Add environment

      ${serv.finish}
    '';
  } else {}) //

  {};


  make-environment = serv:
    (if hasAttr "environment" serv then
    (concatStringsSep ""
    (map (key: ''
      export ${key}
      ${key}=${serv.environment.${key}}
    '') (attrNames serv.environment)))
    else ''
      # Use a simple default path. Don't export.
      PATH=${pkgs.coreutils}/bin:
    '');


  make-directories = serv:
  let
    svc = trace (dump (attrNames serv.systemd.serviceConfig)) serv.systemd.serviceConfig;
    run-dirs =   dumplabel "run-dir"    (fetch "RuntimeDirectory"     svc []);
    run-mode =   dumplabel "run-mode"   (fetch "RuntimeDirectoryMode" svc "");
    state-dirs = dumplabel "state-dir"  (fetch "StateDirectory"       svc []);
    state-mode = dumplabel "state-mode" (fetch "StateDirectoryMode"   svc "");
    user = fetch "User" svc "";
    group = fetch "Group" svc "";

    make-dir = prefix: dir-name: dir-mode:
    ''
      mkdir -p ${make-mode dir-mode} ${prefix}/${dir-name}
      ${if user != ""
      then "chown ${make-user-group} ${prefix}/${dir-name}"
      else ""}
    '';

    make-mode = dir-mode:
      if dir-mode != []
      then '' -m ${dir-mode} ''
      else "";

    make-user-group =
      user + (if group != "" then ":${group}" else "");

  in
    (concatStringsSep "\n" (mapSL (dir: (make-dir "/run"     dir run-mode))   run-dirs))   +
    (concatStringsSep "\n" (mapSL (dir: (make-dir "/var/lib" dir state-mode)) state-dirs)) ;


  make-dependencies = name: serv:
  lib.lists.unique (concatLists [ serv.wants serv.requires serv.requisite serv.binds-to serv.part-of serv.after ]);
  # TODO: use serv.before too. It requires a reverse dependency.

}
