#!/usr/bin/env bash

# The Android platform library of the Ziggy example's smoke tests. See common.sh for what it implements.
#
# The app runs on an emulator or device, driven from the host with adb. Both builds are debug-type APKs, so run-as can read
# what the app writes (the test control port file), and they differ in the Zig library inside: the test build has the test
# hooks and the release-style build has not. The real release variant is built by package-android.sh and is not installable
# for run-as, so it cannot prove the absence of a control connection.
#
# The device is chosen the way the repository's mobile suite chooses one (see apps/smoke-tests/lib/android.sh): the device
# named in PHOTOSPHERE_ANDROID_DEVICES, else a pool emulator, else a plugged-in device. It is claimed under the same
# per-device lock the mobile suite and the pool repair take, for the whole scenario, so a run never installs over an app another
# run is using. The lock is released by ziggy_platform_stop.

ANDROID_EXAMPLE_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example"
ANDROID_SCRIPTS_DIR="$ANDROID_EXAMPLE_DIR/scripts"
ANDROID_APP_ID="dev.ziggy.example"

# Where the app writes its control port, inside its private files directory (the Intent extra carries the full path).
ANDROID_PORT_FILE_DEVICE_PATH="/data/data/$ANDROID_APP_ID/files/ziggy-control-port.txt"

# Seconds a scenario waits for a free device before giving up. The mobile suite's own variable and default.
ANDROID_DEVICE_CLAIM_TIMEOUT="${PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT:-1800}"

# The pool's AVD prefix and the device lock path, from the file that defines them.
source "$ZIGGY_SMOKE_REPO_ROOT/apps/android-frontend/scripts/emulator-config.sh"
# JAVA_HOME and ANDROID_HOME, the way the Photosphere Android app resolves them.
source "$ANDROID_SCRIPTS_DIR/android-common.sh"

# The claimed device's serial and the file descriptor holding its lock, set by ziggy_android_claim_device.
ANDROID_SERIAL_CLAIMED=""
ANDROID_LOCK_FD=""

#
# Runs adb against the claimed device, with the lock's descriptor closed for the command, so nothing adb starts can keep the
# device locked after the scenario has let it go.
#
ziggy_adb() {
    "$ANDROID_HOME/platform-tools/adb" -s "$ANDROID_SERIAL_CLAIMED" "$@" {ANDROID_LOCK_FD}>&-
}

#
# Prints the control port the app wrote, and nothing when it has not written one. adb exec-out puts the device's error
# text on its output, so only a line that is all digits counts as a port.
#
ziggy_android_read_port() {
    ziggy_adb exec-out run-as "$ANDROID_APP_ID" cat files/ziggy-control-port.txt 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || true
}

#
# Prints the devices the run may use, one per line: the named ones, else the pool, else plugged-in devices.
#
ziggy_android_candidate_devices() {
    local adb_command="$ANDROID_HOME/platform-tools/adb"
    local serial avd
    if [ -n "${PHOTOSPHERE_ANDROID_DEVICES:-}" ]; then
        for serial in $PHOTOSPHERE_ANDROID_DEVICES; do
            echo "$serial"
        done
        return 0
    fi
    local pool=""
    local hardware=""
    for serial in $("$adb_command" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        case "$serial" in
            emulator-*)
                avd="$("$adb_command" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
                case "$avd" in
                    "$POOL_AVD_PREFIX"-*)
                        pool="$pool $serial"
                        ;;
                esac
                ;;
            *)
                hardware="$hardware $serial"
                ;;
        esac
    done
    if [ -n "$pool" ]; then
        for serial in $pool; do
            echo "$serial"
        done
        return 0
    fi
    for serial in $hardware; do
        echo "$serial"
    done
}

#
# Claims a device under its lock, waiting for one to be free, and sets ANDROID_SERIAL_CLAIMED and ANDROID_LOCK_FD.
# Returns non-zero when there is no candidate or none came free in time.
#
ziggy_android_claim_device() {
    local waited=0
    local candidates serial fd
    while true; do
        candidates="$(ziggy_android_candidate_devices)"
        if [ -z "$candidates" ]; then
            echo "No pool emulator, named device or plugged-in device is attached." >&2
            return 1
        fi
        for serial in $candidates; do
            exec {fd}<>"$(android_device_lock_path "$serial")"
            if flock -n "$fd"; then
                ANDROID_SERIAL_CLAIMED="$serial"
                ANDROID_LOCK_FD="$fd"
                return 0
            fi
            exec {fd}>&-
        done
        if [ "$waited" -ge "$ANDROID_DEVICE_CLAIM_TIMEOUT" ]; then
            echo "No device came free within ${ANDROID_DEVICE_CLAIM_TIMEOUT}s." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

#
# Hands the claimed device back.
#
ziggy_android_release_device() {
    if [ -n "$ANDROID_LOCK_FD" ]; then
        exec {ANDROID_LOCK_FD}>&-
        ANDROID_LOCK_FD=""
    fi
    ANDROID_SERIAL_CLAIMED=""
}

ziggy_platform_prepare() {
    local run_dir="$1"
    ziggy_android_require_commands zig bun jq unzip adb || return 1
    mkdir -p "$run_dir/test" "$run_dir/release"
    local version
    version="$(ziggy_android_version)"
    bash "$ANDROID_SCRIPTS_DIR/sync-android.sh" --test-hooks --optimize ReleaseSafe || return 1
    ziggy_android_gradle assembleDebug "-PziggyVersionName=$version" || return 1
    cp "$ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk" "$run_dir/test/app.apk" || return 1
    bash "$ANDROID_SCRIPTS_DIR/sync-android.sh" --skip-ui --optimize ReleaseSmall || return 1
    ziggy_android_gradle assembleDebug "-PziggyVersionName=$version" || return 1
    cp "$ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk" "$run_dir/release/app.apk" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local apk="$ZIGGY_SMOKE_RUN_DIR/$kind/app.apk"
    mkdir -p "$test_dir"
    if [ "${3:-}" = "keep-data" ]; then
        # A restart: the same device, the same install and the data the last run left, so only the port file is removed.
        ziggy_adb shell am force-stop "$ANDROID_APP_ID"
        ziggy_adb shell run-as "$ANDROID_APP_ID" rm -f files/ziggy-control-port.txt || return 1
    else
        ziggy_android_claim_device || return 1
        echo "$ANDROID_SERIAL_CLAIMED" > "$test_dir/device.txt"

        # A fresh install with fresh data, so nothing of an earlier scenario is left in the app's files directory.
        ziggy_adb install -r -t "$apk" > "$test_dir/install.log" 2>&1 || {
            cat "$test_dir/install.log" >&2
            return 1
        }
        ziggy_adb shell am force-stop "$ANDROID_APP_ID"
        ziggy_adb shell pm clear "$ANDROID_APP_ID" > /dev/null || return 1
    fi

    ziggy_adb logcat -c
    ziggy_adb shell am start -W -n "$ANDROID_APP_ID/.MainActivity" \
        --ez ziggy.testMode true \
        --es ziggy.testPortFile "$ANDROID_PORT_FILE_DEVICE_PATH" > "$test_dir/am-start.log" 2>&1 || {
        cat "$test_dir/am-start.log" >&2
        return 1
    }
    if [ "$kind" = "release" ]; then
        return 0
    fi

    local waited=0
    local device_port=""
    while true; do
        device_port="$(ziggy_android_read_port)"
        if [ -n "$device_port" ]; then
            break
        fi
        if [ -z "$(ziggy_adb shell pidof "$ANDROID_APP_ID" | tr -d '\r')" ]; then
            echo "The app exited before its control connection came up. Its log:" >&2
            ziggy_adb logcat -d -t 200 >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never wrote its control port." >&2
            ziggy_adb logcat -d -t 200 >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Port 0 asks adb for any free host port, and it prints the one it chose, so two runs never pick the same one.
    local host_port
    host_port="$(ziggy_adb forward tcp:0 "tcp:$device_port" | tr -d '\r\n')" || return 1
    echo "$host_port" > "$test_dir/forward-port.txt"
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="$host_port"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -z "$ANDROID_SERIAL_CLAIMED" ]; then
        return 0
    fi
    if [ -s "$test_dir/forward-port.txt" ]; then
        ziggy_adb forward --remove "tcp:$(cat "$test_dir/forward-port.txt")" || true
        : > "$test_dir/forward-port.txt"
    fi
    ziggy_adb shell am force-stop "$ANDROID_APP_ID" || true
    if [ "${2:-}" = "keep-device" ]; then
        return 0
    fi
    ziggy_android_release_device
}

ziggy_platform_data_dir() {
    local test_dir="$1"
    local data_dir="$test_dir/data"
    mkdir -p "$data_dir"
    # The app's private files directory is read through run-as, which can only stream it, so it is copied out as a tar.
    ziggy_adb exec-out run-as "$ANDROID_APP_ID" tar -cf - -C files . | tar -xf - -C "$data_dir" || return 1
    printf '%s\n' "$data_dir"
}

#
# Whether the app is running, which on Android means its activity exists. Quitting finishes the activity, whose onDestroy
# destroys the core and so stops every thread and task the core started. Android then keeps the emptied process cached for
# a later launch, so a process that is still listed is not a sign the app is still running.
#
ziggy_platform_is_running() {
    ziggy_adb shell dumpsys activity activities | grep -q "$ANDROID_APP_ID/.MainActivity"
}

ziggy_platform_wait_exit() {
    local seconds="$2"
    local waited=0
    while ziggy_platform_is_running; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_artifact_files() {
    local kind="$1"
    local contents_dir="$ZIGGY_SMOKE_RUN_DIR/$kind/apk-contents"
    mkdir -p "$contents_dir"
    unzip -o -q "$ZIGGY_SMOKE_RUN_DIR/$kind/app.apk" 'lib/*' -d "$contents_dir" || return 1
    find "$contents_dir/lib" -name '*.so' | sort
}

ziggy_platform_has_control_port() {
    local port
    port="$(ziggy_android_read_port)"
    [ -n "$port" ]
}

#
# Sends the app to the background, as the Home button does.
#
ziggy_platform_leave_app() {
    ziggy_adb shell input keyevent KEYCODE_HOME
}

#
# Whether the app's process is running, which is what a foreground service keeps going when the app is not in the foreground.
#
ziggy_platform_process_alive() {
    [ -n "$(ziggy_adb shell pidof "$ANDROID_APP_ID" | tr -d '\r')" ]
}

#
# Whether the app's foreground service is running.
#
ziggy_platform_keep_alive_service_running() {
    ziggy_adb shell dumpsys activity services "$ANDROID_APP_ID" | grep -q "ZiggyKeepAliveService"
}
