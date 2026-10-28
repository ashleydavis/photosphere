#!/usr/bin/env bash

# Puts photos and videos into the photo library of the Android device `bun run android` uses, as a camera would, so a test has
# something to import. See add-fixtures-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"
source "$PHOTOSPHERE_CAPACITOR_ANDROID_DIR/scripts/emulator-config.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

serial="${PHOTOSPHERE_ANDROID_TARGET:-}"
files=()
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        -*)
            echo "Usage: add-fixtures-android.sh [--target <adb serial>] <file...>" >&2
            exit 2
            ;;
        *)
            files+=("$1")
            shift
            ;;
    esac
done
if [ "${#files[@]}" -eq 0 ]; then
    echo "Usage: add-fixtures-android.sh [--target <adb serial>] <file...>" >&2
    exit 2
fi

# A relative path is taken from the repo root, because bun runs this script from the app's directory.
paths=()
for file in "${files[@]}"; do
    case "$file" in
        /*)
            path="$file"
            ;;
        *)
            path="$PHOTOSPHERE_REPO_ROOT/$file"
            ;;
    esac
    if [ ! -f "$path" ]; then
        echo "ERROR: there is no file at $path." >&2
        exit 1
    fi
    paths+=("$path")
done

photosphere_android_pick_device "$serial"
serial="$PHOTOSPHERE_ANDROID_SERIAL"

# Prints the MediaStore row of a file in the library by name, if it has one as an image or a video.
media_store_row() {
    "$adb_command" -s "$serial" shell content query --uri content://media/external/file --projection _display_name:media_type \
        | tr -d '\r' | grep "^Row:" | grep "_display_name=$1," | grep -E "media_type=(1|3)" || true
}

# Pushing a file only puts bytes on the filesystem. MediaStore, which is what the app reads the library from, knows nothing about
# them until it scans the file. Some emulator images route that scan to the wrong volume and write no row, so the volume is scanned as
# well when the row is missing, and a file that still has no row stops the script.
for path in "${paths[@]}"; do
    name="$(basename "$path")"
    remote="/sdcard/DCIM/Camera/$name"
    "$adb_command" -s "$serial" shell mkdir -p /sdcard/DCIM/Camera
    "$adb_command" -s "$serial" push "$path" "$remote" > /dev/null
    "$adb_command" -s "$serial" shell content call --uri content://media/external/file --method scan_file --arg "$remote" > /dev/null
    if [ -z "$(media_store_row "$name")" ]; then
        "$adb_command" -s "$serial" shell content call --uri content://media/external --method scan_volume > /dev/null
    fi
    if [ -z "$(media_store_row "$name")" ]; then
        echo "ERROR: $name was pushed to $remote on $serial but MediaStore does not list it as a photo or a video, so the app will not see it." >&2
        exit 1
    fi
    echo "Added $name to the photo library of $serial."
done
