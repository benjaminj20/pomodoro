#!/usr/bin/env bash
# `swiftc` with a workaround for Command Line Tools 16.x, which ships two
# module maps that both define `SwiftBridging` and fails every Foundation
# import with "redefinition of module 'SwiftBridging'". We hide the duplicate
# with a compiler VFS overlay instead of touching system files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAGS=()
INCLUDE="$(dirname "$(xcrun --find swiftc)")/../include/swift"

if [[ -f "$INCLUDE/bridging.modulemap" && -f "$INCLUDE/module.modulemap" ]] \
   && grep -q "module SwiftBridging" "$INCLUDE/module.modulemap"; then
  INCLUDE="$(cd "$INCLUDE" && pwd -P)"
  mkdir -p "$ROOT/build"
  : > "$ROOT/build/empty.modulemap"
  cat > "$ROOT/build/vfs-overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory",
  "name": "$INCLUDE",
  "contents": [ { "type": "file", "name": "bridging.modulemap",
                  "external-contents": "$ROOT/build/empty.modulemap" } ] } ] }
YAML
  FLAGS+=(-vfsoverlay "$ROOT/build/vfs-overlay.yaml")
fi

exec swiftc ${FLAGS[@]+"${FLAGS[@]}"} "$@"
