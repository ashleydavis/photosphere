#!/usr/bin/env bash

# Puts photos and videos into the photo library of the iOS simulator `bun run ios` uses, so a test has something to import. See
# add-fixtures-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos

if [ $# -eq 0 ]; then
    apple_fail "usage: add-fixtures-ios.sh <file...>"
fi

# A relative path is taken from the repo root, because bun runs this script from the app's directory.
paths=()
for file in "$@"; do
    case "$file" in
        /*)
            path="$file"
            ;;
        *)
            path="$APPLE_REPO_ROOT/$file"
            ;;
    esac
    if [ ! -f "$path" ]; then
        apple_fail "there is no file at $path."
    fi
    paths+=("$path")
done

# There is no command that adds photos to a real iPhone's library, so with a device connected, which `bun run ios` would use, there is
# nothing this can do for it.
DEVICE="$(apple_connected_device)"
if [ -n "$DEVICE" ]; then
    apple_fail "the device $DEVICE is connected, and bun run ios would run on it. Photos can be added to a simulator's library only, so add them to the device by hand: AirDrop them or save them to Photos."
fi

UDID="$(apple_pick_simulator)"
xcrun simctl addmedia "$UDID" "${paths[@]}" || apple_fail "could not add the files to the photo library of the simulator $UDID."
echo "Added ${#paths[@]} files to the photo library of the simulator $UDID."
