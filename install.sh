#!/usr/bin/env bash
# Install the ContactSheet plugin into Lightroom Classic's auto-load folder.
# SPDX-License-Identifier: MIT
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/ContactSheet.lrplugin"

case "$(uname -s)" in
  Darwin) DEST="$HOME/Library/Application Support/Adobe/Lightroom/Modules" ;;
  *)      DEST="${APPDATA:-$HOME}/Adobe/Lightroom/Modules" ;;
esac

mkdir -p "$DEST"
rm -rf "$DEST/ContactSheet.lrplugin"
cp -R "$SRC" "$DEST/ContactSheet.lrplugin"

echo "Installed to: $DEST/ContactSheet.lrplugin"
echo "Restart Lightroom (it auto-loads this folder), or add the plugin manually"
echo "via File > Plug-in Manager > Add."
