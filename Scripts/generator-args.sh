#!/usr/bin/env bash
# Prints the swift-ros2-gen package arguments for this repository, one per line, reading the
# IDL that Scripts/fetch-idl.sh put in .idl/.
#   generator-args.sh             every generated distribution (Scripts/regenerate.sh and the
#                                 hash oracle, which selects its row with --distros)
#   generator-args.sh <distro>    only <distro>, labelled @<distro>, to check one distribution's
#                                 IDL alone; rolling reads the Lyrical IDL
set -euo pipefail
DISTROS=${1:-"humble jazzy kilted lyrical"}
for distro in $DISTROS; do
  src=$distro
  [ "$distro" = rolling ] && src=lyrical
  for pkg in builtin_interfaces action_msgs rcl_interfaces; do
    printf -- '--input\n%s=.idl/rcl_interfaces-%s/%s@%s\n' "$pkg" "$src" "$pkg" "$distro"
  done
  printf -- '--input\nunique_identifier_msgs=.idl/unique_identifier_msgs-%s@%s\n' "$src" "$distro"
done
