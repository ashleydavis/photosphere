#!/usr/bin/env bash

# The Android platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# The app runs on an emulator or device, driven from the host with adb. The build is a debug-type APK, so run-as can read what the app
# writes (the test control port file and its log), and its Zig library has the test hooks.
#
# A phone passes no environment to an app, so the settings the desktop sets through PHOTOSPHERE_* variables go in as string Intent
# extras of the same names, which the activity (MainActivity) puts into the process environment before the core is created. They are
# honoured only by a debuggable build.
#
# The core writes its log to a file in the app's private files directory, and the scenario reads app.log on the host, so a stream
# started on the host (adb exec-out run-as ... tail -f) copies the log file into app.log as the core writes it.
#
# The device is chosen the way the repository's mobile suite chooses one (see apps/smoke-tests/lib/android.sh): the device named in
# PHOTOSPHERE_ANDROID_DEVICES, else a pool emulator, else a plugged-in device. It is claimed under the same per-device lock the mobile
# suite and the pool repair take, for as long as the scenario's shell runs: the lock is a file descriptor of that shell, so it is let
# go when the scenario ends, and not between a stop and the restart that follows it, which must find the same install and data.

ANDROID_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"
# JAVA_HOME and ANDROID_HOME, and the helpers that build the app.
source "$ANDROID_SCRIPTS_DIR/android-common.sh"
# The pool's AVD prefix and the device lock path, from the file that defines them.
source "$PHOTOSPHERE_CAPACITOR_ANDROID_DIR/scripts/emulator-config.sh"

# The application id of the app.
ANDROID_APP_ID="$PHOTOSPHERE_ANDROID_APP_ID"

# Where the app writes its control port, inside its private files directory (the Intent extra carries the full path).
ANDROID_PORT_FILE_DEVICE_PATH="/data/data/$ANDROID_APP_ID/files/ziggy-control-port.txt"

# Seconds a scenario waits for a free device before giving up. The mobile suite's own variable and default.
ANDROID_DEVICE_CLAIM_TIMEOUT="${PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT:-1800}"

# The claimed device's serial and the file descriptor holding its lock, set by photosphere_android_claim_device.
ANDROID_SERIAL_CLAIMED=""
ANDROID_LOCK_FD=""

# Set to 1 once this scenario has installed the app on the claimed device, so the APK is installed once and not on every helper.
ANDROID_APK_INSTALLED=""

# Set to 1 once this scenario has wiped the app's data and may have put state in it from outside (seeded databases, settings), so the
# first start keeps what is there and does not wipe it. A scenario that never calls the reset gets a wipe at its first start instead.
ANDROID_DATA_PREPARED=""

# Where the app keeps its settings, relative to the app's private data directory. The activity's Intent extra PHOTOSPHERE_CONFIG_DIR
# (see photosphere_platform_start) points the core's settings directory here, and the core names its files databases.toml and
# config.yaml inside it.
ANDROID_CONFIG_DIR_RELATIVE="files/config"

# Seconds a bridge-attached emulator's wlan0 address is waited for before the emulator is taken to be on user-mode NAT.
ANDROID_HOST_ADDRESS_WAIT_SECONDS=30

#
# Runs adb against the claimed device, with the lock's descriptor closed for the command, so nothing adb starts can keep the device
# locked after the scenario has let it go.
#
photosphere_adb() {
    "$ANDROID_HOME/platform-tools/adb" -s "$ANDROID_SERIAL_CLAIMED" "$@" {ANDROID_LOCK_FD}>&-
}

#
# Prints the control port the app wrote, and nothing when it has not written one. adb exec-out puts the device's error text on its
# output, so only a line that is all digits counts as a port.
#
photosphere_android_read_port() {
    photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat files/ziggy-control-port.txt 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || true
}

#
# Prints the devices the run may use, one per line: the named ones, else the pool, else plugged-in devices.
#
photosphere_android_candidate_devices() {
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

# The address every emulator must be able to reach for a scenario to work: this host, on the LAN bridge.
ANDROID_HOST_BRIDGE_ADDRESS="192.168.55.1"

# Seconds a reachability probe is given before the device counts as unreachable.
ANDROID_REACH_PROBE_SECONDS=10

#
# Whether a device can still reach this host. An emulator is asked to ping the host on the LAN bridge. A real device is asked whether
# adb can still reach it, because it reaches this host through the reverses adb sets up over USB. Read-only. Always true when the run
# declares it has no LAN bridge (PHOTOSPHERE_NO_LAN_BRIDGE=1).
# Usage: photosphere_android_can_reach_host <serial>
#
photosphere_android_can_reach_host() {
    local serial="$1"
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        return 0
    fi
    case "$serial" in
        emulator-*)
            timeout "$ANDROID_REACH_PROBE_SECONDS" "$ANDROID_HOME/platform-tools/adb" -s "$serial" shell "ping -c 1 -W 1 $ANDROID_HOST_BRIDGE_ADDRESS" >/dev/null 2>&1
            return $?
            ;;
    esac
    timeout "$ANDROID_REACH_PROBE_SECONDS" "$ANDROID_HOME/platform-tools/adb" -s "$serial" shell true >/dev/null 2>&1
}

#
# Prints how many scenarios may run at once: one per candidate device that can reach this host, and at least one.
#
photosphere_platform_parallelism() {
    local serial count=0
    for serial in $(photosphere_android_candidate_devices); do
        if photosphere_android_can_reach_host "$serial"; then
            count=$((count + 1))
        fi
    done
    if [ "$count" -lt 1 ]; then
        count=1
    fi
    echo "$count"
}

#
# Claims a device under its lock, waiting for one to be free, and sets ANDROID_SERIAL_CLAIMED and ANDROID_LOCK_FD. Succeeds at once
# when a device is already claimed. Returns non-zero when there is no candidate or none came free in time.
#
photosphere_android_claim_device() {
    if [ -n "$ANDROID_SERIAL_CLAIMED" ]; then
        return 0
    fi
    local waited=0
    local candidates serial fd
    while true; do
        candidates="$(photosphere_android_candidate_devices)"
        if [ -z "$candidates" ]; then
            echo "No pool emulator, named device or plugged-in device is attached." >&2
            return 1
        fi
        for serial in $candidates; do
            exec {fd}<>"$(android_device_lock_path "$serial")"
            if flock -n "$fd"; then
                # A device that cannot reach this host would fail every scenario given to it, so it is let go and passed over.
                if photosphere_android_can_reach_host "$serial"; then
                    ANDROID_SERIAL_CLAIMED="$serial"
                    ANDROID_LOCK_FD="$fd"
                    return 0
                fi
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
# Refuses to wipe the app's data on a real phone unless the run was told it may, the way the mobile suite does: an emulator holds
# nothing but what a test put there, and a phone holds whatever its owner imported. Set PHOTOSPHERE_ALLOW_DEVICE_WIPE=1 to say the
# phone is yours to wipe.
#
photosphere_android_require_wipe_allowed() {
    case "$ANDROID_SERIAL_CLAIMED" in
        emulator-*)
            return 0
            ;;
    esac
    if [ "${PHOTOSPHERE_ALLOW_DEVICE_WIPE:-}" = "1" ]; then
        return 0
    fi
    echo "Refusing to wipe the app's data on $ANDROID_SERIAL_CLAIMED, which is a real phone and may hold an imported library. Run this against the emulator pool, or set PHOTOSPHERE_ALLOW_DEVICE_WIPE=1 if the phone's data is yours to destroy." >&2
    return 1
}

#
# Prints the architecture name the build scripts use for each device the run may use, one per line without repeats.
#
photosphere_android_architectures() {
    local serial abi
    for serial in $(photosphere_android_candidate_devices); do
        abi="$("$ANDROID_HOME/platform-tools/adb" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')"
        case "$abi" in
            x86_64)
                echo "x86_64"
                ;;
            arm64-v8a)
                echo "arm64"
                ;;
            *)
                echo "The device $serial has the ABI '$abi', which Photosphere does not build for." >&2
                return 1
                ;;
        esac
    done | sort -u
}

photosphere_platform_prepare() {
    local run_dir="$1"
    photosphere_android_require_commands zig bun jq adb || return 1
    mkdir -p "$run_dir/test"
    local architectures
    architectures="$(photosphere_android_architectures)" || return 1
    if [ -z "$architectures" ]; then
        echo "No pool emulator, named device or plugged-in device is attached, so there is no architecture to build for." >&2
        return 1
    fi
    bash "$ANDROID_SCRIPTS_DIR/sync-android.sh" --test-hooks --optimize ReleaseSafe --arch "$(printf '%s ' $architectures)" || return 1
    photosphere_android_gradle assembleDebug "-PziggyVersionName=$(photosphere_android_version)" || return 1
    cp "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk" "$run_dir/test/app.apk" || return 1
}

#
# Installs the app's APK on the claimed device, once per scenario shell. Installing over an installed app keeps its data, so this is
# safe after the scenario has seeded state. The helpers that write into the app's private directory call it first, because run-as
# needs the app installed. Claims the device first. The log of the install goes to the given directory, or to stderr on failure.
# Usage: photosphere_android_ensure_installed <log_dir>
#
photosphere_android_ensure_installed() {
    local log_dir="$1"
    photosphere_android_claim_device || return 1
    if [ "$ANDROID_APK_INSTALLED" = "1" ]; then
        return 0
    fi
    mkdir -p "$log_dir"
    photosphere_adb install -r -t "$PHOTOSPHERE_SMOKE_RUN_DIR/test/app.apk" > "$log_dir/install.log" 2>&1 || {
        cat "$log_dir/install.log" >&2
        return 1
    }
    ANDROID_APK_INSTALLED=1
}

#
# Starts the app for one scenario. Sets PHOTOSPHERE_CONTROL_HOST and PHOTOSPHERE_CONTROL_PORT to where the test control connection can
# be reached from the host. The settings and logs are in the app's private files directory, which is the scenario's: the first
# start installs the app and, unless the scenario wiped the data itself with photosphere_platform_reset_app_state (and may have seeded
# state since), clears its data. Every later start in the scenario keeps the data, as a desktop scenario's directory is kept.
# Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    mkdir -p "$test_dir"
    photosphere_android_claim_device || return 1
    echo "$ANDROID_SERIAL_CLAIMED" > "$test_dir/device.txt"
    photosphere_android_ensure_installed "$test_dir" || return 1
    photosphere_adb shell am force-stop "$ANDROID_APP_ID"
    if [ "${2:-}" = "keep-data" ] || [ -f "$test_dir/log-generation.txt" ]; then
        # A restart: the same device, the same install and the data the last run left, so only the port file is removed. A second
        # start in a scenario is always a restart, because the scenario's seeded databases and settings are in that data.
        photosphere_adb shell run-as "$ANDROID_APP_ID" rm -f files/ziggy-control-port.txt || return 1
    elif [ "$ANDROID_DATA_PREPARED" != "1" ]; then
        # The first start of a scenario that did not wipe the app's data itself: fresh data, so nothing of an earlier scenario is left
        # in the app's files directory. A scenario that did wipe it, and may have put state in since, keeps that state.
        photosphere_android_require_wipe_allowed || return 1
        photosphere_adb shell pm clear "$ANDROID_APP_ID" > /dev/null || return 1
    fi
    # Granted on every start, after any wipe of the data (which revokes it), so no scenario is left on a permission dialog nothing can tap.
    photosphere_android_grant_notification_permission || return 1
    if [ ! -f "$test_dir/log-generation.txt" ]; then
        echo 0 > "$test_dir/log-generation.txt"
    fi

    # Each start writes its log to a directory of its own, so the stream below copies only this start's log, as the desktop's app.log
    # holds only the run it belongs to.
    local generation
    generation=$(($(cat "$test_dir/log-generation.txt") + 1))
    echo "$generation" > "$test_dir/log-generation.txt"
    local log_dir="files/logs-$generation"

    # Every value is quoted for the device's shell, which adb hands the whole command line to.
    local extras="--ez ziggy.testMode true --es ziggy.testPortFile '$ANDROID_PORT_FILE_DEVICE_PATH'"
    extras="$extras --es PHOTOSPHERE_TEST_MODE '1'"
    extras="$extras --es PHOTOSPHERE_CONFIG_DIR '/data/data/$ANDROID_APP_ID/files/config'"
    extras="$extras --es PHOTOSPHERE_LOG_DIR '/data/data/$ANDROID_APP_ID/$log_dir'"
    if [ -n "${PHOTOSPHERE_NEWS_URL:-}" ]; then
        extras="$extras --es PHOTOSPHERE_NEWS_URL '$PHOTOSPHERE_NEWS_URL'"
    fi

    photosphere_adb logcat -c
    photosphere_adb shell "am start -W -n $ANDROID_APP_ID/.MainActivity $extras" > "$test_dir/am-start.log" 2>&1 || {
        cat "$test_dir/am-start.log" >&2
        return 1
    }

    # The log file appears when the core is created. The glob matches the main log and not the errors log beside it.
    local log_glob="$log_dir/logs/photosphere-????-??-??T??-??-??.log"
    local waited=0
    while ! photosphere_adb exec-out "run-as $ANDROID_APP_ID sh -c 'ls $log_glob'" 2>/dev/null | grep -q "^$log_dir/logs/photosphere-"; do
        if [ -z "$(photosphere_adb shell pidof "$ANDROID_APP_ID" | tr -d '\r')" ]; then
            echo "The app exited before it made its log. The device's log:" >&2
            photosphere_adb logcat -d -t 200 >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never made its log file." >&2
            photosphere_adb logcat -d -t 200 >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$test_dir/app.log" photosphere_adb exec-out "run-as $ANDROID_APP_ID sh -c 'tail -n +1 -f $log_glob'") || return 1
    echo "$pgid" > "$test_dir/log-stream.pgid"

    waited=0
    local device_port=""
    while true; do
        device_port="$(photosphere_android_read_port)"
        if [ -n "$device_port" ]; then
            break
        fi
        if [ -z "$(photosphere_adb shell pidof "$ANDROID_APP_ID" | tr -d '\r')" ]; then
            echo "The app exited before its control connection came up. Its log:" >&2
            cat "$test_dir/app.log" >&2
            photosphere_adb logcat -d -t 200 >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never wrote its control port." >&2
            cat "$test_dir/app.log" >&2
            photosphere_adb logcat -d -t 200 >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Port 0 asks adb for any free host port, and it prints the one it chose, so two runs never pick the same one.
    local host_port
    host_port="$(photosphere_adb forward tcp:0 "tcp:$device_port" | tr -d '\r\n')" || return 1
    echo "$host_port" > "$test_dir/forward-port.txt"
    PHOTOSPHERE_CONTROL_HOST=127.0.0.1
    PHOTOSPHERE_CONTROL_PORT="$host_port"
    export PHOTOSPHERE_CONTROL_HOST PHOTOSPHERE_CONTROL_PORT
}

#
# Stops the app and the log stream and removes the port forward. The device stays claimed until the scenario's shell ends, so a
# restart on the same data finds the same install. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    if [ -z "$ANDROID_SERIAL_CLAIMED" ]; then
        return 0
    fi
    if [ -s "$test_dir/forward-port.txt" ]; then
        photosphere_adb forward --remove "tcp:$(cat "$test_dir/forward-port.txt")" || true
        : > "$test_dir/forward-port.txt"
    fi
    photosphere_adb shell am force-stop "$ANDROID_APP_ID" || true
    if [ -s "$test_dir/log-stream.pgid" ]; then
        kill_process_group "$(cat "$test_dir/log-stream.pgid")" || true
        : > "$test_dir/log-stream.pgid"
    fi
}

#
# Whether the app is running, which on Android means its activity exists. Quitting finishes the activity, whose onDestroy destroys the
# core and so stops every thread and task the core started. Android then keeps the emptied process cached for a later launch, so a
# process that is still listed is not a sign the app is still running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    photosphere_adb shell dumpsys activity activities | grep -q "$ANDROID_APP_ID/.MainActivity"
}

#
# Waits for the app to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local seconds="$2"
    local waited=0
    while photosphere_platform_is_running "$1"; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Clears everything the app has stored on the device: its files directory (settings, vault, logs), the web view's storage and the
# keystore entries, which is what `pm clear` removes with the app stopped. Installs the app first, because the scenario puts state in
# from outside after this (seeded databases and settings), which needs the app installed, and marks the data as the scenario's own so
# the first start does not wipe what was put in. Claims the device first, because it runs before the app is started.
#
photosphere_platform_reset_app_state() {
    photosphere_android_claim_device || return 1
    photosphere_android_require_wipe_allowed || return 1
    photosphere_android_ensure_installed "$PHOTOSPHERE_SMOKE_RUN_DIR/test" || return 1
    photosphere_adb shell am force-stop "$ANDROID_APP_ID"
    local result
    result="$(photosphere_adb shell pm clear "$ANDROID_APP_ID" 2>&1 | tr -d '\r')"
    if [ "$result" != "Success" ]; then
        echo "Could not clear the app's stored data on $ANDROID_SERIAL_CLAIMED: $result" >&2
        return 1
    fi
    ANDROID_DATA_PREPARED=1
}

#
# The name scenarios call to clear the app's stored data, which is ${PLATFORM}_reset_app_state.
#
android_reset_app_state() {
    photosphere_platform_reset_app_state
}

#
# Prepares the app's private directory for a scenario's seeding: the device claimed, the app installed, and the data marked as the
# scenario's own, so the first start keeps what is seeded. The seed helpers all begin with it.
#
photosphere_android_prepare_for_seeding() {
    photosphere_android_ensure_installed "$PHOTOSPHERE_SMOKE_RUN_DIR/test" || return 1
    ANDROID_DATA_PREPARED=1
}

#
# Prints the address the emulator or device uses to reach this host. A bridge-attached emulator has a 192.168.55.x address on wlan0 and
# reaches the host at 192.168.55.1, where the 10.0.2.2 alias is dead; a plain user-mode NAT emulator reaches the host at 10.0.2.2. A
# real device gets 127.0.0.1, which is right only because android_expose_host_port reverses each host port a scenario serves onto the
# device. PHOTOSPHERE_ANDROID_TEST_HOST overrides all of it. PHOTOSPHERE_NO_LAN_BRIDGE=1 says the run has no bridge, so the wlan0 poll,
# which could never succeed, is skipped. The device must already be claimed (android_expose_host_port claims it), because this is
# called inside $(...) and a claim made there would be let go with the subshell. Every message goes to stderr, because stdout is the
# address.
#
android_host_address() {
    if [ -n "${PHOTOSPHERE_ANDROID_TEST_HOST:-}" ]; then
        echo "$PHOTOSPHERE_ANDROID_TEST_HOST"
        return 0
    fi
    if [ -z "$ANDROID_SERIAL_CLAIMED" ]; then
        echo "android_host_address needs a claimed device. Call android_expose_host_port first, which claims one." >&2
        return 1
    fi
    case "$ANDROID_SERIAL_CLAIMED" in
        emulator-*)
            ;;
        *)
            echo "127.0.0.1"
            return 0
            ;;
    esac
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        echo "10.0.2.2"
        return 0
    fi

    # The wlan0 address is polled and not sampled once, because a bridge-attached emulator drops it for a few seconds at a time when
    # its wifi re-associates, and reading that as "not on the bridge" would hand back the dead 10.0.2.2 alias.
    local waited=0
    while true; do
        if photosphere_adb shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
            echo "192.168.55.1"
            return 0
        fi
        if [ "$waited" -ge "$ANDROID_HOST_ADDRESS_WAIT_SECONDS" ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "wlan0 never took a 192.168.55.x address in ${waited}s; treating this as a NAT-only emulator." >&2
    echo "10.0.2.2"
}

#
# Makes a port the host is listening on reachable from the device at the address android_host_address prints. On a real device that is
# `adb reverse`, so 127.0.0.1 on the phone is this host. On an emulator it does nothing, because the guest reaches the host directly.
# Claims the device, which must be done in the scenario's own shell and not in a $(...) subshell.
# Usage: android_expose_host_port <port>
#
android_expose_host_port() {
    local port="$1"
    photosphere_android_claim_device || return 1
    case "$ANDROID_SERIAL_CLAIMED" in
        emulator-*)
            return 0
            ;;
    esac
    photosphere_adb reverse "tcp:$port" "tcp:$port" > /dev/null || return 1
    echo "Reversed host port $port onto $ANDROID_SERIAL_CLAIMED, so the device reaches it at 127.0.0.1:$port" >&2
}

#
# Copies a file from the host into the app's private data directory. adb push cannot write app-private storage, so the file goes
# through the world-readable temporary directory and run-as copies it in. Usage: photosphere_android_put_file <host_file> <path_under_data_dir>
#
photosphere_android_put_file() {
    local host_file="$1"
    local device_path="$2"
    local staged="/data/local/tmp/photosphere-seed-$$-$(basename "$device_path")"
    photosphere_adb push "$host_file" "$staged" > /dev/null || return 1
    photosphere_adb shell run-as "$ANDROID_APP_ID" mkdir -p "$(dirname "$device_path")" || return 1
    photosphere_adb shell run-as "$ANDROID_APP_ID" cp "$staged" "$device_path" || return 1
    photosphere_adb shell rm -f "$staged" > /dev/null 2>&1 || true
}

#
# Prints the absolute path, on the device, of a name inside the app's files directory, which is where android_seed_database puts a
# fixture. The app resolves no relative path against its storage, so a scenario types or writes this path rather than the name.
# Usage: android_app_path <relative_path_under_files>
#
android_app_path() {
    echo "/data/data/$ANDROID_APP_ID/files/$1"
}

#
# Copies a database fixture from the host into the app's files directory, the place android_app_path names. A copy already there is replaced. Usage: android_seed_database <host_fixture_dir> <relative_dest_under_files>
#
android_seed_database() {
    local host_src="$1"
    local rel_dest="$2"
    local staged="/data/local/tmp/photosphere-seed-$$-$(basename "$host_src")"
    photosphere_android_prepare_for_seeding || return 1
    photosphere_adb shell rm -rf "$staged" > /dev/null 2>&1 || true
    photosphere_adb push "$host_src" "$staged" > /dev/null || return 1
    photosphere_adb shell run-as "$ANDROID_APP_ID" rm -rf "files/$rel_dest" || return 1
    # The destination's parents are made too: a nested destination fails the copy with "No such file or directory" otherwise.
    photosphere_adb shell run-as "$ANDROID_APP_ID" mkdir -p "files/$(dirname "$rel_dest")" || return 1
    photosphere_adb shell run-as "$ANDROID_APP_ID" cp -r "$staged" "files/$rel_dest" || return 1
    photosphere_adb shell rm -rf "$staged" > /dev/null 2>&1 || true
    echo "Seeded database fixture '$(basename "$host_src")' into the app's files directory at files/$rel_dest" >&2
}

#
# Writes the app's databases.toml into its settings directory, registering the given databases and recent-database names, from
# outside the app and before it starts, as a desktop scenario pre-writes the file. The first two arguments are JSON: the databases as
# an array of {name, path} (description, origin, s3Key, encryptionKey and geocodingKey optional), and the recents as an array of names,
# empty when omitted. The third is the path of the database the app reopens on launch; omitted, no such key is written, which leaves the
# app on the welcome screen. Paths are written as given.
# Usage: android_seed_databases_config '<databases json>' ['<recent names json>'] ['<last database path>']
#
android_seed_databases_config() {
    local databases_json="$1"
    local recent_json="${2:-[]}"
    local last_database="${3:-}"
    photosphere_android_prepare_for_seeding || return 1
    local rendered
    rendered="$(mktemp)"
    if ! jq -rn --argjson databases "$databases_json" --argjson recent "$recent_json" --arg last "$last_database" '
        "recent_database_names = \($recent | tojson)",
        (if $last != "" then "last_database = \($last | tojson)" else empty end),
        ($databases[] |
            "",
            "[[databases]]",
            "name = \(.name | tojson)",
            "description = \((.description // "") | tojson)",
            "path = \(.path | tojson)",
            (if .origin then "origin = \(.origin | tojson)" else empty end),
            (if .s3Key then "s3_key = \(.s3Key | tojson)" else empty end),
            (if .encryptionKey then "encryption_key = \(.encryptionKey | tojson)" else empty end),
            (if .geocodingKey then "geocoding_key = \(.geocodingKey | tojson)" else empty end))
    ' > "$rendered"; then
        echo "Could not render the app's database list from: $databases_json" >&2
        rm -f "$rendered"
        return 1
    fi
    photosphere_android_put_file "$rendered" "$ANDROID_CONFIG_DIR_RELATIVE/databases.toml" || {
        rm -f "$rendered"
        return 1
    }
    rm -f "$rendered"
    echo "Wrote the app's database list to $ANDROID_CONFIG_DIR_RELATIVE/databases.toml" >&2
}

#
# Prints the app's databases.toml as it stands on the device, or nothing when there is none yet, which is how a scenario asserts on a
# write the app made. Usage: android_read_databases_config
#
android_read_databases_config() {
    photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat "$ANDROID_CONFIG_DIR_RELATIVE/databases.toml" 2>/dev/null | grep -v ": No such file or directory$" || true
}

#
# Writes the syncing settings into the sync section of the app's config.yaml in its settings directory, keeping every other section
# the file already has. A database path says which database the background sync pushes, which the app otherwise records itself when
# one is opened. The pause is left out, so the app's default applies, when none is given.
# Usage: android_seed_sync_config <enabled true|false> <only_on_wifi true|false> [pause_ms] [database_path]
#
android_seed_sync_config() {
    local enabled="$1"
    local only_on_wifi="$2"
    local pause_ms="${3:-}"
    local database_path="${4:-}"
    local value
    for value in "$enabled" "$only_on_wifi"; do
        if [ "$value" != "true" ] && [ "$value" != "false" ]; then
            echo "android_seed_sync_config takes true or false for enabled and only_on_wifi, got: $value" >&2
            return 1
        fi
    done
    if [ -n "$pause_ms" ] && ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "android_seed_sync_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    photosphere_android_prepare_for_seeding || return 1

    # The file as it stands, minus its sync section, which runs from the line "sync:" to the next line that is not indented.
    local rendered
    rendered="$(mktemp)"
    photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat "$ANDROID_CONFIG_DIR_RELATIVE/config.yaml" 2>/dev/null \
        | tr -d '\r' \
        | sed -e '/^sync:/,/^[^[:space:]]/{/^sync:/d;/^[[:space:]]/d}' \
        | grep -v ': No such file or directory$' > "$rendered" || true
    {
        echo "sync:"
        echo "  enabled: $enabled"
        echo "  only_on_wifi: $only_on_wifi"
        if [ -n "$pause_ms" ]; then
            echo "  pause_between_runs_ms: $pause_ms"
        fi
        if [ -n "$database_path" ]; then
            echo "  database_path: $(jq -n --arg path "$database_path" '$path')"
        fi
    } >> "$rendered"
    photosphere_android_put_file "$rendered" "$ANDROID_CONFIG_DIR_RELATIVE/config.yaml" || {
        rm -f "$rendered"
        return 1
    }
    rm -f "$rendered"
    echo "Wrote the app's syncing settings to $ANDROID_CONFIG_DIR_RELATIVE/config.yaml (enabled=$enabled, onlyOnWifi=$only_on_wifi)" >&2
}

#
# Grants the app the photo library permission from outside the app, so no permission dialog has to be tapped. Which permissions depend
# on the device's API level, as the app's own request does. Each is read back, because `pm grant` says nothing useful when it does not
# take, and an app without the permission reads an empty library and not an error.
# Usage: android_grant_media_permission
#
android_grant_media_permission() {
    photosphere_android_prepare_for_seeding || return 1
    local sdk
    sdk="$(photosphere_adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    local permissions
    if [ "${sdk:-0}" -ge 34 ]; then
        permissions="android.permission.READ_MEDIA_IMAGES android.permission.READ_MEDIA_VIDEO android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
    elif [ "${sdk:-0}" -ge 33 ]; then
        permissions="android.permission.READ_MEDIA_IMAGES android.permission.READ_MEDIA_VIDEO"
    else
        permissions="android.permission.READ_EXTERNAL_STORAGE"
    fi
    local permission
    for permission in $permissions; do
        # The grant is often refused harmlessly because the permission is already held, so the read-back below is the check.
        photosphere_adb shell pm grant "$ANDROID_APP_ID" "$permission" > /dev/null 2>&1 || true
        if ! photosphere_adb shell dumpsys package "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | grep -q "$permission: granted=true"; then
            echo "$permission is not granted to $ANDROID_APP_ID after asking for it, so the app would read an empty photo library rather than fail" >&2
            return 1
        fi
    done
    echo "Granted the photo library permission from outside the app" >&2
}

#
# Grants the notification permission from outside the app, for the scenarios that start a foreground service. Android 13 and later
# need POST_NOTIFICATIONS for that, and the app would otherwise wait on a dialog nothing can tap. Nothing to do below Android 13.
# Usage: android_grant_notification_permission
#
android_grant_notification_permission() {
    photosphere_android_prepare_for_seeding || return 1
    photosphere_android_grant_notification_permission
}

#
# Grants POST_NOTIFICATIONS to the installed app and checks it was granted. Below Android 13 there is nothing to grant. The app asks for
# it when background syncing starts, which any scenario that opens a database with syncing on reaches, and a dialog left on the screen
# when the next start force-stops the app takes that start's task with it.
#
photosphere_android_grant_notification_permission() {
    local sdk
    sdk="$(photosphere_adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    if [ "${sdk:-0}" -lt 33 ]; then
        echo "Notifications need no permission on API ${sdk:-unknown}" >&2
        return 0
    fi
    photosphere_adb shell pm grant "$ANDROID_APP_ID" android.permission.POST_NOTIFICATIONS > /dev/null 2>&1 || true
    if ! photosphere_adb shell dumpsys package "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | grep -q "android.permission.POST_NOTIFICATIONS: granted=true"; then
        echo "android.permission.POST_NOTIFICATIONS is not granted to $ANDROID_APP_ID after asking for it, so the app would wait on a permission dialog no scenario can tap" >&2
        return 1
    fi
    echo "Granted the notification permission from outside the app" >&2
}

#
# Removes a path under the app's files directory so a scenario that creates fresh state there can be run again. Installs the app first,
# because run-as needs it. Fails when the removal fails. Usage: android_reset_path <relative_path_under_files>
#
android_reset_path() {
    local rel="$1"
    photosphere_android_prepare_for_seeding || return 1
    photosphere_adb shell run-as "$ANDROID_APP_ID" rm -rf "files/$rel" || return 1
}

#
# Waits until the given path under the app's files directory exists and is non-empty (for a directory, lists at least one entry), to
# see a background task's effect on storage the host cannot reach. Returns 0 once it is there, non-zero after DEFAULT_WAIT_TIMEOUT seconds.
# Usage: android_wait_for_file <relative_path_under_files>
#
android_wait_for_file() {
    local rel="$1"
    local deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if photosphere_adb shell run-as "$ANDROID_APP_ID" ls "files/$rel" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    return 1
}
