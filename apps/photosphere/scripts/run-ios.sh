#!/usr/bin/env bash

# Builds the iOS app and runs it: on a connected device when there is one, otherwise on an existing simulator, otherwise it
# fails with an error. See run-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos

# An optional test database to put on the simulator, as run-android.sh takes one: 50, 1 or 0 for 50-assets, 1-asset and no-assets, or
# the name of any directory under test/dbs. Checked before anything slow happens, so a wrong name fails at once.
fixture_dir=""
case "${1:-}" in
    "")
        ;;
    50)
        fixture_dir="50-assets"
        ;;
    1)
        fixture_dir="1-asset"
        ;;
    0)
        fixture_dir="no-assets"
        ;;
    *)
        fixture_dir="$1"
        ;;
esac
if [ -n "$fixture_dir" ] && [ ! -d "$APPLE_REPO_ROOT/test/dbs/$fixture_dir" ]; then
    apple_fail "there is no fixture database at test/dbs/$fixture_dir."
fi
UDID="$(apple_connected_device)"
if [ -n "$UDID" ]; then
    if [ -n "$fixture_dir" ]; then
        apple_fail "a test database can be put on a simulator only, and the device $UDID is connected."
    fi
    bash "$SCRIPT_DIR/build-ios.sh" --sdk device --arch arm64
    APP="$APPLE_APP_DIR/native/ios/zig-out/xcode/Build/Products/Debug-iphoneos/Photosphere.app"
    node "$SCRIPT_DIR/ios-device.ts" install "$UDID" au.com.codecapers.photosphere.ziggy "$APP"
    # The helper launches the app under the device's debugserver, paused, and lldb detaches from it, which lets it run on
    # by itself. A launch that just drops the debugserver connection, as native-run's does, ends the app with it.
    INFO_FILE="$(mktemp "${TMPDIR:-/tmp}/ziggy-run-ios-XXXXXX")"
    node "$SCRIPT_DIR/ios-device.ts" launch "$UDID" au.com.codecapers.photosphere.ziggy "$INFO_FILE" &
    LAUNCH_PID=$!
    while [ ! -s "$INFO_FILE" ]; do
        kill -0 "$LAUNCH_PID" 2>/dev/null || apple_fail "the app could not be launched on $UDID."
        sleep 0.2
    done
    xcrun lldb --batch \
        -o "platform select remote-ios" \
        -o "target create \"$APP/Photosphere\"" \
        -o "process connect connect://127.0.0.1:$(jq -r '.port' "$INFO_FILE")" \
        -o "process detach" > /dev/null || apple_fail "lldb could not start the app on $UDID."
    wait "$LAUNCH_PID"
    rm -f "$INFO_FILE"
    echo "Launched au.com.codecapers.photosphere.ziggy on $UDID"
    exit 0
fi
bash "$SCRIPT_DIR/build-ios.sh" --sdk simulator
UDID="$(apple_pick_simulator)"
APP="$APPLE_APP_DIR/native/ios/zig-out/xcode/Build/Products/Debug-iphonesimulator/Photosphere.app"
xcrun simctl install "$UDID" "$APP"

# The fixture is copied into the app's storage directory, Application Support named for its bundle identifier, and registered in
# databases.toml in its settings directory, $HOME/.config/photosphere, where HOME is the app's data container, so the app opens it
# on launch. The container is on this machine's filesystem, so a copy is enough. The copy is made over any copy an earlier run left.
if [ -n "$fixture_dir" ]; then
    CONTAINER="$(xcrun simctl get_app_container "$UDID" au.com.codecapers.photosphere.ziggy data)" || apple_fail "the app has no data container on the simulator $UDID."
    DATABASE_DIR="$CONTAINER/Library/Application Support/au.com.codecapers.photosphere.ziggy/$fixture_dir"
    CONFIG_DIR="$CONTAINER/.config/photosphere"
    mkdir -p "$DATABASE_DIR" "$CONFIG_DIR"
    cp -R "$APPLE_REPO_ROOT/test/dbs/$fixture_dir/." "$DATABASE_DIR/"
    EXISTING_CONFIG="$(mktemp)"
    if [ -f "$CONFIG_DIR/databases.toml" ]; then
        cp "$CONFIG_DIR/databases.toml" "$EXISTING_CONFIG"
    fi
    (cd "$APPLE_APP_DIR" && bun scripts/write-fixture-databases-config.ts "$fixture_dir" "$DATABASE_DIR" "$EXISTING_CONFIG" "$CONFIG_DIR/databases.toml")
    rm -f "$EXISTING_CONFIG"
    echo "Registered test-$fixture_dir in the app's database list. The app opens it on launch."
fi
open -a Simulator
xcrun simctl launch --console-pty "$UDID" au.com.codecapers.photosphere.ziggy
