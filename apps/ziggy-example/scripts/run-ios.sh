#!/usr/bin/env bash

# Builds the iOS app and runs it: on a connected device when there is one, otherwise on an existing simulator, otherwise it
# fails with an error. See run-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
UDID="$(apple_connected_device)"
if [ -n "$UDID" ]; then
    bash "$SCRIPT_DIR/build-ios.sh" --sdk device --arch arm64
    APP="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/xcode/Build/Products/Debug-iphoneos/ZiggyExample.app"
    node "$SCRIPT_DIR/ios-device.ts" install "$UDID" dev.ziggy.example "$APP"
    # The helper launches the app under the device's debugserver, paused, and lldb detaches from it, which lets it run on
    # by itself. A launch that just drops the debugserver connection, as native-run's does, ends the app with it.
    INFO_FILE="$(mktemp "${TMPDIR:-/tmp}/ziggy-run-ios-XXXXXX")"
    node "$SCRIPT_DIR/ios-device.ts" launch "$UDID" dev.ziggy.example "$INFO_FILE" &
    LAUNCH_PID=$!
    while [ ! -s "$INFO_FILE" ]; do
        kill -0 "$LAUNCH_PID" 2>/dev/null || apple_fail "the app could not be launched on $UDID."
        sleep 0.2
    done
    xcrun lldb --batch \
        -o "platform select remote-ios" \
        -o "target create \"$APP/ZiggyExample\"" \
        -o "process connect connect://127.0.0.1:$(jq -r '.port' "$INFO_FILE")" \
        -o "process detach" > /dev/null || apple_fail "lldb could not start the app on $UDID."
    wait "$LAUNCH_PID"
    rm -f "$INFO_FILE"
    echo "Launched dev.ziggy.example on $UDID"
    exit 0
fi
bash "$SCRIPT_DIR/build-ios.sh" --sdk simulator
UDID="$(apple_pick_simulator)"
APP="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/xcode/Build/Products/Debug-iphonesimulator/ZiggyExample.app"
xcrun simctl install "$UDID" "$APP"
open -a Simulator
xcrun simctl launch --console-pty "$UDID" dev.ziggy.example
