#!/bin/bash
# Packages build/Metrics.app into build/Metrics.dmg — a compressed (UDZO) disk
# image containing the app plus an /Applications symlink for drag-to-install.
# Used locally and by the Release workflow (.github/workflows/release.yml).
#
# Usage: scripts/make_dmg.sh   (run ./build.sh first to produce build/Metrics.app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Metrics.app"
DMG="build/Metrics.dmg"
STAGING="build/dmg"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run ./build.sh first" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Metrics" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "✓ Built $DMG"
