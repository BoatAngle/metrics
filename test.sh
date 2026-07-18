#!/bin/bash
# Runs the unit-test suite (Tests/MetricsTests) under Command Line Tools.
#
# CLT ships swift-testing but hides its pieces from the default search paths,
# so three extra flags are required:
#   • -plugin-path …/host/plugins/testing   — the @Test/#expect macro plugin,
#     which lives in a subdirectory the compiler doesn't scan on its own;
#   • -rpath …/Library/Developer/Frameworks — where Testing.framework lives;
#   • -rpath …/Library/Developer/usr/lib    — lib_TestingInterop.dylib,
#     which Testing.framework links against.
# All three are derived from `xcode-select -p` so this works on CI too.
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN="$(xcode-select -p)"

exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$TOOLCHAIN/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$TOOLCHAIN/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$TOOLCHAIN/Library/Developer/usr/lib" \
  "$@"
