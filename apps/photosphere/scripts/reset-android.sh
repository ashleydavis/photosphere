#!/usr/bin/env bash

# Wipes everything Photosphere has stored on an Android emulator, so the next `bun run android` starts from a fresh install. It
# works on an emulator only and refuses a real device. See reset-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"
source "$PHOTOSPHERE_ANDROID_TOOLS_DIR/emulator-config.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

serial="${PHOTOSPHERE_ANDROID_TARGET:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        *)
            echo "Usage: reset-android.sh [--target <adb serial>]" >&2
            exit 2
            ;;
    esac
done

# The device is picked the way run-android.sh picks it, so the reset lands on the one the next `bun run android` uses. That puts a
# real device first, and the checks below refuse it rather than wipe it.
requested="$serial"
photosphere_android_pick_device "$serial"
serial="$PHOTOSPHERE_ANDROID_SERIAL"

# The two checks that keep this off a real device. An emulator's adb serial starts with emulator-, and its kernel reports itself as
# QEMU. A device whose serial was made to look like an emulator's still fails the second.
case "$serial" in
    emulator-*)
        ;;
    *)
        echo "ERROR: $serial is not an emulator. This script never touches a real device." >&2
        exit 1
        ;;
esac
qemu="$("$adb_command" -s "$serial" shell getprop ro.kernel.qemu | tr -d '\r')"
if [ "$qemu" != "1" ]; then
    echo "ERROR: $serial does not report itself as an emulator (ro.kernel.qemu is '$qemu'). This script never touches a real device." >&2
    exit 1
fi

# A named emulator is wiped only while its device lock is held, by whoever is using it, for the whole time they use it. Taking the
# lock here instead would mean the caller letting go of it for the reset, and a smoke run queued on the lock takes the emulator in
# that gap. The picker already holds the lock for an emulator it chose itself.
if [ -n "$requested" ]; then
    exec 8<>"$(android_device_lock_path "$serial")"
    if flock -n 8; then
        echo "ERROR: $serial is not locked. Hold $(android_device_lock_path "$serial") for as long as you use the emulator, then reset it." >&2
        exit 1
    fi
    exec 8>&-
fi

if ! "$adb_command" -s "$serial" shell pm list packages "$PHOTOSPHERE_ANDROID_APP_ID" | tr -d '\r' | grep -qx "package:$PHOTOSPHERE_ANDROID_APP_ID"; then
    echo "Photosphere is not installed on $serial, so there is nothing to wipe."
    exit 0
fi

# pm clear removes the app's storage, its settings and its keystore entries, and puts its permissions back to never having been
# asked. The app is stopped first, so nothing it still has open is written back afterwards.
"$adb_command" -s "$serial" shell am force-stop "$PHOTOSPHERE_ANDROID_APP_ID"
result="$("$adb_command" -s "$serial" shell pm clear "$PHOTOSPHERE_ANDROID_APP_ID" 2>&1 | tr -d '\r')"
if [ "$result" != "Success" ]; then
    echo "ERROR: pm clear on $serial said: $result" >&2
    exit 1
fi
echo "Wiped Photosphere's data on $serial ($("$adb_command" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r'))."
