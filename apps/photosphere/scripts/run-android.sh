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

# Without a named target, a plugged-in device wins, then the hand-testing emulator, then a running smoke test pool emulator.
# A pool emulator is taken only while its device lock is free, the lock the smoke tests and the pool repair take, so a run
# never installs over an app a test is using. The lock is held until this script ends.
if [ -z "$serial" ]; then
    pool_candidates=""
    for candidate in $("$adb_command" devices | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        case "$candidate" in
            emulator-*)
                avd="$("$adb_command" -s "$candidate" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
                case "$avd" in
                    "$SINGLE_AVD_NAME")
                        if [ -z "$serial" ]; then
                            serial="$candidate"
                        fi
                        ;;
                    "$POOL_AVD_PREFIX"-*)
                        pool_candidates="$pool_candidates $candidate"
                        ;;
                esac
                ;;
            *)
                serial="$candidate"
                break
                ;;
        esac
    done
    if [ -z "$serial" ]; then
        for candidate in $pool_candidates; do
            exec {lock_fd}<>"$(android_device_lock_path "$candidate")"
            if flock -n "$lock_fd"; then
                serial="$candidate"
                break
            fi
            exec {lock_fd}>&-
        done
    fi
fi
if [ -z "$serial" ]; then
    echo "ERROR: there is no device, hand-testing emulator ($SINGLE_AVD_NAME) or free pool emulator attached. A pool emulator that a test is using is left alone. Pass --target <serial> to name one." >&2
    exit 1
fi

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
# way into the app's private storage, which works because the debug build is debuggable.
if [ -n "$fixture_dir" ]; then
    echo "Copying the $fixture_dir database into the app's storage..."
    tar -C "$PHOTOSPHERE_REPO_ROOT/test/dbs" -cf - "$fixture_dir" | "$adb_command" -s "$serial" exec-in run-as "$PHOTOSPHERE_ANDROID_APP_ID" tar -C files -xf -

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
    tar -C "$config_dir" -cf - databases.toml | "$adb_command" -s "$serial" exec-in run-as "$PHOTOSPHERE_ANDROID_APP_ID" tar -C files -xf -
    echo "Registered test-$fixture_dir in the app's database list. The app opens it on launch."
fi

"$adb_command" -s "$serial" shell am start -n "$PHOTOSPHERE_ANDROID_APP_ID/.MainActivity"
