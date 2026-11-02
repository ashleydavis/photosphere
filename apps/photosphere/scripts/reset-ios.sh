#!/usr/bin/env bash

# Wipes everything Photosphere has stored on an iOS simulator, so the next `bun run ios` starts from a fresh install. It works on a
# simulator only and refuses a real device. See reset-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

BUNDLE_ID="au.com.codecapers.photosphere.ziggy"

apple_require_macos

# run-ios.sh puts a connected device first, so with one connected the next `bun run ios` would go to it rather than to the simulator
# this wiped. That is refused rather than guessed around.
DEVICE="$(apple_connected_device)"
if [ -n "$DEVICE" ]; then
    apple_fail "the real device $DEVICE is connected, and bun run ios would run on it rather than on a simulator. This script never touches a real device. Disconnect it first."
fi

# The simulator run-ios.sh would pick. simctl reaches simulators only, so nothing below can reach a device.
UDID="$(apple_pick_simulator)"

# Uninstalling removes the app's container: its Documents, its Library and the web view's storage. The photo permission and the
# keychain are kept by the simulator rather than in the container, so they are reset as well, which leaves the simulator as a fresh
# install would find it.
if xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" > /dev/null 2>&1; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" || apple_fail "could not uninstall $BUNDLE_ID from the simulator $UDID."
fi
xcrun simctl privacy "$UDID" reset photos || apple_fail "could not reset the photo permission on the simulator $UDID."
xcrun simctl keychain "$UDID" reset || apple_fail "could not reset the keychain of the simulator $UDID."
echo "Wiped Photosphere's data on the simulator $UDID."
