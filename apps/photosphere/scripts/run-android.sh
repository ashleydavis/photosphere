#!/usr/bin/env bash

# Builds Photosphere, installs it on an emulator or device and starts it. See run-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"
source "$PHOTOSPHERE_CAPACITOR_ANDROID_DIR/scripts/emulator-config.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

serial="${PHOTOSPHERE_ANDROID_TARGET:-}"
fixture=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        -*)
            echo "Usage: run-android.sh [--target <adb serial>] [fixture]" >&2
            exit 2
            ;;
        *)
            if [ -n "$fixture" ]; then
                echo "Usage: run-android.sh [--target <adb serial>] [fixture]" >&2
                exit 2
            fi
            fixture="$1"
            shift
            ;;
    esac
done

# The short fixture names map to the directories under test/dbs, and any other name is a directory there. Checked before anything
# slow happens, so a wrong name fails at once.
fixture_dir=""
case "$fixture" in
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
        fixture_dir="$fixture"
        ;;
esac
if [ -n "$fixture_dir" ] && [ ! -d "$PHOTOSPHERE_REPO_ROOT/test/dbs/$fixture_dir" ]; then
    echo "ERROR: there is no fixture database at test/dbs/$fixture_dir. These are the fixtures:" >&2
    ls "$PHOTOSPHERE_REPO_ROOT/test/dbs" | sed 's/^/  /' >&2
    exit 1
fi

photosphere_android_pick_device "$serial"
serial="$PHOTOSPHERE_ANDROID_SERIAL"

echo "Running on $serial ($("$adb_command" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r'))."
abi="$("$adb_command" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
    x86_64)
        arch="x86_64"
        ;;
    arm64-v8a)
        arch="arm64"
        ;;
    *)
        echo "ERROR: $serial has the ABI $abi, which Photosphere does not build for." >&2
        exit 1
        ;;
esac

bash "$PHOTOSPHERE_ANDROID_SCRIPTS_DIR/sync-android.sh" --arch "$arch" --optimize Debug
photosphere_android_gradle assembleDebug "-PziggyVersionName=$(photosphere_android_version)"
"$adb_command" -s "$serial" install -r "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"

# The fixture is copied into the app's files directory and registered in its databases.toml there, which is the app's settings
# directory when it is started normally, so the app opens it on launch. Both go in as a tar stream unpacked by run-as, the only
# way into the app's private storage, which works because the debug build is debuggable. They go through adb shell rather than
# exec-in, because exec-in returns before the device has finished unpacking and does not pass back the remote exit code.
if [ -n "$fixture_dir" ]; then
    echo "Copying the $fixture_dir database into the app's storage..."

    # A wiped app (pm clear, as android:reset does) has no files directory until it first runs, and tar cannot unpack into a
    # directory that is not there.
    "$adb_command" -s "$serial" shell run-as "$PHOTOSPHERE_ANDROID_APP_ID" mkdir -p files
    tar -C "$PHOTOSPHERE_REPO_ROOT/test/dbs" -cf - "$fixture_dir" | "$adb_command" -s "$serial" shell run-as "$PHOTOSPHERE_ANDROID_APP_ID" tar -C files -xf -

    # A device with no databases registered has no databases.toml, and that starts from an empty one. A file that is there but
    # cannot be read stops the run, because writing over it would lose the user's entries.
    config_dir="$(mktemp -d)"
    existing_config="$(mktemp)"
    trap 'rm -f "$existing_config" "$config_dir/databases.toml"; rmdir "$config_dir"' EXIT
    if "$adb_command" -s "$serial" shell run-as "$PHOTOSPHERE_ANDROID_APP_ID" ls files/databases.toml > /dev/null 2>&1; then
        if ! "$adb_command" -s "$serial" exec-out run-as "$PHOTOSPHERE_ANDROID_APP_ID" cat files/databases.toml > "$existing_config"; then
            echo "ERROR: the app's databases.toml on $serial could not be read, so it is not written over." >&2
            exit 1
        fi
    fi
    (cd "$PHOTOSPHERE_APP_DIR" && bun scripts/write-fixture-databases-config.ts "$fixture_dir" "/data/data/$PHOTOSPHERE_ANDROID_APP_ID/files/$fixture_dir" "$existing_config" "$config_dir/databases.toml")
    tar -C "$config_dir" -cf - databases.toml | "$adb_command" -s "$serial" shell run-as "$PHOTOSPHERE_ANDROID_APP_ID" tar -C files -xf -
    echo "Registered test-$fixture_dir in the app's database list. The app opens it on launch."
fi

"$adb_command" -s "$serial" shell am start -n "$PHOTOSPHERE_ANDROID_APP_ID/.MainActivity"
