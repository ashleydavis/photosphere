#!/usr/bin/env bash

# Builds the iOS app for the simulator, installs it on an existing simulator and launches it. See run-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
bash "$SCRIPT_DIR/build-ios.sh" --sdk simulator
UDID="$(apple_pick_simulator)"
APP="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/xcode/Build/Products/Debug-iphonesimulator/ZiggyExample.app"
xcrun simctl install "$UDID" "$APP"
open -a Simulator
xcrun simctl launch --console-pty "$UDID" dev.ziggy.example
