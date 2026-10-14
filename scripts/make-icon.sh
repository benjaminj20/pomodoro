#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
scripts/swiftc.sh -O -o "$TMP/make-icon" scripts/make-icon.swift
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "✓ Wrote Resources/AppIcon.icns"
