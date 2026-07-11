#!/bin/bash
# Builds Metrics.app from the SwiftPM package.
# Usage: ./build.sh [debug|release] [--run] [--install]
#   --run      launch the freshly built bundle from build/
#   --install  replace /Applications/Metrics.app and launch that copy
set -euo pipefail
cd "$(dirname "$0")"

CONF="release"
RUN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONF="$arg" ;;
    --run) RUN=1 ;;
    --install) INSTALL=1 ;;
  esac
done

APP_NAME="Metrics"
APP_DIR="build/$APP_NAME.app"

echo "▸ swift build -c $CONF (universal: arm64 + x86_64)"
# The dual-arch build (XCBuild-backed) has unreliable incremental tracking
# under Command Line Tools — it can relink stale objects and silently ship
# old code. Clean its output first; the full universal build is ~25 s.
rm -rf .build/out .build/apple
swift build -c "$CONF" --arch arm64 --arch x86_64
# Universal builds land in a different products directory.
BIN_DIR=".build/out/Products/$(echo "$CONF" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
if [ ! -f "$BIN_DIR/$APP_NAME" ]; then
  BIN_DIR=".build/apple/Products/$(echo "$CONF" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
fi

echo "▸ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# App icon (best effort — the app works fine without it)
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build
  if swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null 2>&1; then
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || true
  fi
fi
if [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cp "$BIN_DIR/MetricsFanHelper" "$APP_DIR/Contents/Resources/metrics-fan-helper"

# CLI companion (Package 9). Lands next to the main executable so the app can
# find it, and so a user can symlink it onto their PATH:
#   ln -s "/Applications/Metrics.app/Contents/MacOS/metricsctl" /usr/local/bin/metricsctl
cp "$BIN_DIR/metricsctl" "$APP_DIR/Contents/MacOS/metricsctl"

echo "▸ Assembling MetricsWidgets.appex"
APPEX="$APP_DIR/Contents/Extensions/MetricsWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN_DIR/MetricsWidgets" "$APPEX/Contents/MacOS/MetricsWidgets"
cp Resources/MetricsWidgets-Info.plist "$APPEX/Contents/Info.plist"

echo "▸ Codesigning (ad-hoc)"
codesign --force --sign - "$APP_DIR/Contents/Resources/metrics-fan-helper"
codesign --force --sign - "$APP_DIR/Contents/MacOS/metricsctl"
codesign --force --sign - "$APPEX"
codesign --force --deep --sign - "$APP_DIR"

echo "✓ Built $APP_DIR"
if [ "$INSTALL" = 1 ]; then
  echo "▸ Installing to /Applications"
  pkill -x Metrics 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Metrics.app
  cp -R "$APP_DIR" /Applications/
  open /Applications/Metrics.app
elif [ "$RUN" = 1 ]; then
  open "$APP_DIR"
fi
