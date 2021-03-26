# Dump:
# Make a nicely indented string of any object.

obj:
with builtins;

let
  dumpAttrSet = depth: obj:
  let
    names = attrNames obj;
    dumpAttr = name: obj: (indent depth) + (toString name) + " = " + (dump2 depth obj) + ";";
  in
  concatStringsSep " " (map (name: (dumpAttr name (getAttr name obj))) names);
  
  indent = depth: "\n" + (foldl' (x: y: x + y) "" (genList (x: " ") depth));
  
  dump2 = depth: obj:
  if isInt      obj then (toString obj) else
  if isFloat    obj then (toString obj) else
  if isString   obj then "\"" + (toString obj) + "\"" else
  if isBool     obj then  (if obj then "true" else "false") else
  if isNull     obj then "null" else
  if isFunction obj then "<function>" else
  if isList     obj then "[" + (concatStringsSep " " (map (dump2 depth) obj)) + "]" else
  if isAttrs    obj then "{" + (dumpAttrSet (depth + 2) obj) + (indent depth)  + "}" else
  "<something else>"    ;
in
dump2 0 obj

# Usage

# trace ( dump <my-value> <return-value> )
# Show the pretty printed <my-value> while returning the <return-value> to the enclosing function.

# tip: Show the value of <bar> before it gets feed into function <foo>
# let
#    dumpit = x: trace (dump x) x;
# in
#    foo(dumpit(bar));
