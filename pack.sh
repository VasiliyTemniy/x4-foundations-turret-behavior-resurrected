#!/usr/bin/env bash
set -euo pipefail

MOD="vas_turret_behavior_resurrected"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/packages/$MOD"
TS="$(date +%d-%m-%Y_%H%M%S)"
ZIP="$ROOT/packages/${MOD}_${TS}.zip"

rm -rf "$PKG"
mkdir -p "$PKG"

cp    "$ROOT/content.xml"         "$PKG/content.xml"
cp    "$ROOT/turret_behavior.lua" "$PKG/turret_behavior.lua"
cp -r "$ROOT/md"                  "$PKG/md"
cp -r "$ROOT/t"                   "$PKG/t"

(cd "$ROOT/packages" && zip -r -9 "$ZIP" "$MOD")

echo "Packed: $ZIP"
