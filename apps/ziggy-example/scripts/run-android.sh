#!/usr/bin/env bash

# Builds the example, installs it on an emulator or device and starts it. See run-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"
source "$ZIGGY_CAPACITOR_ANDROID_DIR/scripts/emulator-config.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

serial="${ZIGGY_ANDROID_TARGET:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        *)
            echo "Usage: run-android.sh [--target <adb serial>]" >&2
            exit 2
            ;;
    esac
done

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

abi="$("$adb_command" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
    x86_64)
        arch="x86_64"
        ;;
    arm64-v8a)
        arch="arm64"
        ;;
    *)
        echo "ERROR: $serial has the ABI $abi, which the example does not build for." >&2
        exit 1
        ;;
esac

bash "$ZIGGY_ANDROID_SCRIPTS_DIR/sync-android.sh" --arch "$arch" --optimize Debug
ziggy_android_gradle assembleDebug "-PziggyVersionName=$(ziggy_android_version)"
"$adb_command" -s "$serial" install -r "$ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
"$adb_command" -s "$serial" shell am start -n "$ZIGGY_ANDROID_APP_ID/.MainActivity"
