#!/usr/bin/env bash
# Build a distributable release: a zipped ContactSheet.lrplugin that users unzip and
# add via Lightroom > File > Plug-in Manager (or drop into the Modules folder).
# Pure Lua — no build step, just package the bundle. Version comes from Info.lua.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$ROOT/ContactSheet.lrplugin"

# VERSION = { major = M, minor = N, revision = R, ... } in Info.lua → "M.N.R".
read -r MAJ MIN REV <<<"$(grep -oE '(major|minor|revision) = [0-9]+' "$PLUGIN/Info.lua" \
  | grep -oE '[0-9]+' | head -3 | tr '\n' ' ')"
VER="$MAJ.$MIN.$REV"

DIST="$ROOT/dist"
ZIP="$DIST/ContactSheet-$VER.lrplugin.zip"

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto --keepParent keeps the ContactSheet.lrplugin folder inside the archive.
ditto -c -k --keepParent "$PLUGIN" "$ZIP"

echo
echo "Release artifact: $ZIP"
echo "Version: $VER"
shasum -a 256 "$ZIP"
