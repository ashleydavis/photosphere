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
# Prints the devices the run may use, one per line: the named ones, else the pool, else plugged-in devices, else any other
# emulator, such as the single hand-testing one.
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
    local other_emulators=""
    for serial in $("$adb_command" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        case "$serial" in
            emulator-*)
                avd="$("$adb_command" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
                case "$avd" in
                    "$POOL_AVD_PREFIX"-*)
                        pool="$pool $serial"
                        ;;
                    *)
                        other_emulators="$other_emulators $serial"
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
    if [ -n "$hardware" ]; then
        for serial in $hardware; do
            echo "$serial"
        done
        return 0
    fi
    for serial in $other_emulators; do
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
# Prints how many devices scenarios can run on at once: one per candidate device that can reach this host, and at least one.
#
photosphere_platform_device_limit() {
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
            echo "No emulator, named device or plugged-in device is attached." >&2
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
    # In the app's cache directory and not its files directory, which is the storage sandbox that "reset device" empties: a log inside it would
    # be deleted from under the stream that copies it to app.log, and the lines the app writes after the reset would never reach the host.
    local log_dir="cache/logs-$generation"

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
    # Without the media location permission Android strips the GPS tags from the photos the app reads from the library.
    if [ "${sdk:-0}" -ge 29 ]; then
        permissions="$permissions android.permission.ACCESS_MEDIA_LOCATION"
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
# True when this target's app data may be wiped, which is every emulator and no phone, unless PHOTOSPHERE_ALLOW_DEVICE_WIPE=1 says the
# phone is the person's to wipe. Needs a claimed device. Usage: android_may_wipe_app_data
#
android_may_wipe_app_data() {
    photosphere_android_claim_device || return 1
    photosphere_android_require_wipe_allowed 2>/dev/null
}

#
# The directory pushed test photos go into on the device, which is where a camera puts them.
#
ANDROID_MEDIA_DIR="/sdcard/DCIM/Camera"

#
# Puts a photo into the device's photo library, from outside the app.
#
# Two steps, and both are needed: pushing the file only puts bytes on the filesystem, and MediaStore is a database that knows nothing
# about them until it is told. `cmd media rescan` is not available on the emulator image (there is no "media" service), so the scan goes
# through the provider's own scan_file method, which is. A directory can be named to put the photo somewhere other than the camera
# folder. MediaStore groups items into albums by the directory they sit in, so a scenario that gives its photos their own directory gets
# its own album, and can point automatic import at that album alone. On a phone holding somebody else's photo library that is the
# difference between importing two photos and importing all of them.
# Usage: android_seed_media <host_file> <remote_name> [remote_dir]
#
android_seed_media() {
    local host_src="$1"
    local remote_name="$2"
    local remote_dir="${3:-$ANDROID_MEDIA_DIR}"
    local remote_path="$remote_dir/$remote_name"
    photosphere_android_claim_device || return 1

    photosphere_adb shell mkdir -p "$remote_dir" >/dev/null 2>&1 || true
    photosphere_adb push "$host_src" "$remote_path" >/dev/null || return 1

    local scan_result
    scan_result="$(photosphere_adb shell content call --uri content://media/external/file --method scan_file --arg "$remote_path" 2>&1 | tr -d '\r')"
    if ! echo "$scan_result" | grep -q "Result:"; then
        echo "MediaStore would not scan $remote_path: $scan_result" >&2
        return 1
    fi

    # The scan returning a result is not the same as the photo being in MediaStore. On the API 33 emulator the scan answers `Result:` as
    # it always does and then routes the insert to the internal volume, which refuses anything outside the system media directories, so
    # the row is never written and the app's query over the external volume finds nothing. Asking the row for itself is the only answer
    # that means what the log line claims.
    if ! android_media_store_has "$remote_name"; then
        # Scanning the volume rather than the file leaves no room for the path to be resolved to the wrong volume, because the volume
        # is what is named.
        photosphere_adb shell content call --uri content://media/external --method scan_volume >/dev/null 2>&1 || true

        if ! android_media_store_has "$remote_name"; then
            # The row is printed when there is one, because "not indexed" and "indexed as something the app does not read" are
            # different faults with the same symptom.
            echo "MediaStore does not hold $remote_path as an image or a video, so automatic import will never see it. The scan said: $scan_result" >&2
            echo "MediaStore row: $(android_media_store_row "$remote_name" || echo "none")" >&2
            return 1
        fi
    fi

    # A pending row belongs to whoever created it and MediaStore hides it from every other app, so the photo is in the library for adb
    # and invisible to Photosphere. The API 33 emulator indexes a scanned file with is_pending=1, and the app read `files=0 images=0
    # video=0` from inside its own process while this helper found the row from the shell that owns it.
    if android_media_store_row "$remote_name" | grep -q "is_pending=1"; then
        # By the row's own id, against the item's URI. The collection URI refuses this outright with "Movement of content://media/
        # external/file which isn't part of well-defined collection not allowed".
        local row_id
        row_id="$(android_media_store_row "$remote_name" | sed 's/.*_id=\([0-9]*\),.*/\1/')"
        photosphere_adb shell content update --uri "content://media/external/file/$row_id" --bind is_pending:i:0 >/dev/null 2>&1 || true

        if android_media_store_row "$remote_name" | grep -q "is_pending=1"; then
            echo "MediaStore holds $remote_path as pending, so no app but its owner can see it, and clearing that failed" >&2
            echo "MediaStore row: $(android_media_store_row "$remote_name")" >&2
            return 1
        fi
    fi

    echo "Put '$remote_name' into the device photo library: $(android_media_store_row "$remote_name")" >&2
}

#
# Prints MediaStore's row for a photo, by the name it was seeded under, or nothing when there is none. Asked of the external volume,
# which is the collection the app reads. media_type is in the projection because the app does not ask for every file: it selects
# MEDIA_TYPE IN (image, video), so a row indexed as a plain file is one the app will never see. There is no --where, because its quoting
# does not survive the trip through adb the same way on every API level, and a where clause the provider rejects is a filter that is
# not applied. The filtering is a grep. is_pending and owner_package_name are here because a row can be present and still invisible to
# every app but the one that wrote it.
# Usage: android_media_store_row <remote_name>
#
android_media_store_row() {
    local remote_name="$1"
    photosphere_adb shell content query --uri content://media/external/file \
        --projection _id:_display_name:media_type:volume_name:is_pending:owner_package_name \
        2>&1 | tr -d '\r' | grep "^Row:" | grep "_display_name=$remote_name,"
}

#
# Prints the album id MediaStore has filed a seeded photo under, or nothing when it has none. An album on Android is a bucket, and a
# bucket is the directory its items sit in: MediaStore derives BUCKET_ID from the path, so every directory is its own album and there
# is no separate album to create. This is what a scenario asks after seeding its first photo into a directory of its own, so it can
# point automatic import at that album and nothing else.
# Usage: android_media_album_id <remote_name>
#
android_media_album_id() {
    local remote_name="$1"
    photosphere_adb shell content query --uri content://media/external/file \
        --projection _display_name:bucket_id \
        2>&1 | tr -d '\r' | grep "^Row:" | grep "_display_name=$remote_name," \
        | sed 's/.*bucket_id=\([-0-9][0-9]*\).*/\1/' | head -1
}

#
# Whether MediaStore holds the photo as media the app can import: present, and typed as an image (1) or a video (3) rather than as an
# untyped file. Usage: android_media_store_has <remote_name>
#
android_media_store_has() {
    local remote_name="$1"
    android_media_store_row "$remote_name" | grep -qE "media_type=(1|3)"
}

#
# Removes a photo a scenario put into the device photo library, so the next run starts clean. The directory must be given when the photo
# was seeded into one: the row goes from MediaStore and the file stays on disk otherwise, so the next scan of the volume puts it back.
# Usage: android_remove_media <remote_name> [remote_dir]
#
android_remove_media() {
    local remote_name="$1"
    local remote_dir="${2:-$ANDROID_MEDIA_DIR}"
    photosphere_android_claim_device || return 1
    photosphere_adb shell rm -f "$remote_dir/$remote_name" >/dev/null 2>&1 || true
    photosphere_adb shell content delete --uri content://media/external/file --where "_display_name='$remote_name'" >/dev/null 2>&1 || true
}

#
# Removes every photo whose name starts with the given prefix from the device photo library. This is for the start of a scenario rather
# than the end of one: a run killed outright never reaches its exit trap, and the photo it left behind would be imported by the next run
# and throw its counts out. Safe because a scenario holds its device under a lock for its whole run.
# Usage: android_remove_media_matching <name_prefix> [remote_dir]
#
android_remove_media_matching() {
    local prefix="$1"
    local remote_dir="${2:-$ANDROID_MEDIA_DIR}"
    photosphere_android_claim_device || return 1
    photosphere_adb shell "rm -f $remote_dir/$prefix*" >/dev/null 2>&1 || true
    photosphere_adb shell content delete --uri content://media/external/file --where "_display_name LIKE '$prefix%'" >/dev/null 2>&1 || true
}

#
# The photo library permissions the app asks for on the claimed device, by API level, one per line. Android 14 added the selected-photos
# permission to the two per-type ones; Android 13 has only the per-type ones, and older releases the one storage permission.
#
photosphere_android_media_permissions() {
    local sdk
    sdk="$(photosphere_adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    if [ "${sdk:-0}" -ge 34 ]; then
        echo "android.permission.READ_MEDIA_IMAGES"
        echo "android.permission.READ_MEDIA_VIDEO"
        echo "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
    elif [ "${sdk:-0}" -ge 33 ]; then
        echo "android.permission.READ_MEDIA_IMAGES"
        echo "android.permission.READ_MEDIA_VIDEO"
    else
        echo "android.permission.READ_EXTERNAL_STORAGE"
    fi
}

#
# Refuses the app the photo library permission, from outside the app, in a way that answers the next request without a dialog. Revoking
# alone is not enough: the next request would put the system dialog up, and a scenario cannot tap it. The user-fixed flag is what the
# system sets when a user chooses "Don't allow" and means it, and a request for a user-fixed permission comes straight back as denied.
# From Android 14 the selected-photos permission goes with them: leaving it would leave the app holding the photos the user picked,
# which is a partial grant and not the refusal this is asked to set up.
# Usage: android_refuse_media_permission
#
android_refuse_media_permission() {
    photosphere_android_prepare_for_seeding || return 1
    local permission result
    for permission in $(photosphere_android_media_permissions); do
        photosphere_adb shell pm revoke "$ANDROID_APP_ID" "$permission" >/dev/null 2>&1 || true
        result="$(photosphere_adb shell pm set-permission-flags "$ANDROID_APP_ID" "$permission" user-fixed 2>&1 | tr -d '\r')"
        if [ -n "$result" ]; then
            echo "Could not mark $permission as refused on $ANDROID_SERIAL_CLAIMED: $result" >&2
            return 1
        fi
    done
    echo "Refused the photo library permission, as a user who chose \"Don't allow\"" >&2
}

#
# Gives the app access to only the photos the user picked, from outside the app. This is the third answer Android 14 added to the photo
# permission, set up the way a refusal is, because a scenario cannot tap the picker either: the two per-type permissions are revoked and
# marked user-fixed so the next request comes straight back without a dialog, and the selected-photos permission is granted, which is
# the state the platform leaves behind when a user chooses "Select photos". Refuses on a device older than Android 14 rather than
# quietly setting up something else.
# Usage: android_grant_partial_media_permission
#
android_grant_partial_media_permission() {
    photosphere_android_prepare_for_seeding || return 1
    local sdk
    sdk="$(photosphere_adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    if [ "${sdk:-0}" -lt 34 ]; then
        echo "Partial photo access needs Android 14 or later, and $ANDROID_SERIAL_CLAIMED is API ${sdk:-unknown}" >&2
        return 1
    fi

    local permission result
    for permission in android.permission.READ_MEDIA_IMAGES android.permission.READ_MEDIA_VIDEO; do
        photosphere_adb shell pm revoke "$ANDROID_APP_ID" "$permission" >/dev/null 2>&1 || true
        result="$(photosphere_adb shell pm set-permission-flags "$ANDROID_APP_ID" "$permission" user-fixed 2>&1 | tr -d '\r')"
        if [ -n "$result" ]; then
            echo "Could not mark $permission as refused on $ANDROID_SERIAL_CLAIMED: $result" >&2
            return 1
        fi
    done

    photosphere_adb shell pm grant "$ANDROID_APP_ID" android.permission.READ_MEDIA_VISUAL_USER_SELECTED >/dev/null 2>&1 || true

    # Read back, because a `pm grant` that did not take leaves the app with no access at all, which is the refusal path, and the scenario
    # would then pass for the wrong reason.
    if ! photosphere_adb shell dumpsys package "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | grep -q "android.permission.READ_MEDIA_VISUAL_USER_SELECTED: granted=true"; then
        echo "android.permission.READ_MEDIA_VISUAL_USER_SELECTED is not granted to $ANDROID_APP_ID after asking for it, so this would test a refusal rather than a partial grant" >&2
        return 1
    fi
    echo "Gave the app access to only the photos the user picked" >&2
}

#
# Writes the automatic import settings into the auto_import section of the app's config.yaml in its settings directory, keeping every
# other section the file already has. This is how a scenario starts with automatic import already on, writing into a database it
# seeded itself, or off with the album it should watch already chosen. An album id restricts the import to that one album, which is
# what makes a scenario runnable against a phone with a real photo library. The default database path must be a path the app can
# open, so a scenario passes android_app_path of the database. Left out, the app makes its own default database. The pause between
# passes is left out, so the app's default applies, when none is given.
# Usage: android_seed_auto_import_config <enabled true|false> [default_database_path] [pause_ms] [album_id]
#
android_seed_auto_import_config() {
    local enabled="$1"
    local default_database_path="${2:-}"
    local pause_ms="${3:-}"
    local album_id="${4:-}"
    if [ "$enabled" != "true" ] && [ "$enabled" != "false" ]; then
        echo "android_seed_auto_import_config takes true or false for enabled, got: $enabled" >&2
        return 1
    fi
    if [ -n "$pause_ms" ] && ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "android_seed_auto_import_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    photosphere_android_prepare_for_seeding || return 1

    # The file as it stands, minus its auto_import section, which runs from the line "auto_import:" to the next line that is not indented.
    local rendered
    rendered="$(mktemp)"
    photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat "$ANDROID_CONFIG_DIR_RELATIVE/config.yaml" 2>/dev/null \
        | tr -d '\r' \
        | sed -e '/^auto_import:/,/^[^[:space:]]/{/^auto_import:/d;/^[[:space:]]/d}' \
        | grep -v ': No such file or directory$' > "$rendered" || true
    {
        echo "auto_import:"
        echo "  enabled: $enabled"
        if [ -n "$pause_ms" ]; then
            echo "  pause_between_runs_ms: $pause_ms"
        fi
        if [ -n "$album_id" ]; then
            echo "  sources:"
            echo "    - type: device-album"
            echo "      album_id: $(jq -n --arg album "$album_id" '$album')"
        fi
        if [ -n "$default_database_path" ]; then
            echo "  default_database_path: $(jq -n --arg path "$default_database_path" '$path')"
        fi
    } >> "$rendered"
    photosphere_android_put_file "$rendered" "$ANDROID_CONFIG_DIR_RELATIVE/config.yaml" || {
        rm -f "$rendered"
        return 1
    }
    rm -f "$rendered"
    echo "Wrote the app's automatic import settings to $ANDROID_CONFIG_DIR_RELATIVE/config.yaml (enabled=$enabled)" >&2
}

#
# Copies a file of the app's private data directory (a path under /data/data/<app id>) onto this machine, so a scenario can put it back
# afterwards. This is what lets a scenario run against a real phone without wiping it: `pm clear` is the clean start an emulator gets,
# and it is not available on a phone that holds somebody's photo library, so a device run borrows the settings and hands them back.
# Writes the file to the given local path, or removes that path when the device has no such file, so the caller can tell "there was one"
# from "there was not" by whether the file exists afterwards. A file that is there and cannot be copied fails, because a restore that
# took that for an absent file would delete the device's own.
# Usage: android_save_app_data_file <path_under_app_data_dir> <local_path>
#
android_save_app_data_file() {
    local device_path="$1"
    local local_path="$2"
    photosphere_android_prepare_for_seeding || return 1

    rm -f "$local_path"
    if ! photosphere_adb shell run-as "$ANDROID_APP_ID" test -f "$device_path" >/dev/null 2>&1; then
        echo "The device has no $device_path to save" >&2
        return 0
    fi
    if ! photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat "$device_path" > "$local_path" 2>/dev/null; then
        rm -f "$local_path"
        echo "Could not save $device_path from the device, and it is there. Refusing to carry on: this run would have nothing to put back." >&2
        return 1
    fi
    if [ ! -s "$local_path" ]; then
        rm -f "$local_path"
        echo "Saving $device_path from the device produced an empty file, and it is not empty there." >&2
        return 1
    fi
    echo "Saved the device's $device_path, to be put back at the end of the scenario" >&2
}

#
# Puts back a file saved by android_save_app_data_file, or removes the one this run left when the device had none.
# Usage: android_restore_app_data_file <path_under_app_data_dir> <local_path>
#
android_restore_app_data_file() {
    local device_path="$1"
    local local_path="$2"
    photosphere_android_claim_device || return 1
    local staged="/data/local/tmp/psphere-restore-$$-$(basename "$device_path")"

    if [ -f "$local_path" ]; then
        photosphere_adb push "$local_path" "$staged" >/dev/null || return 1
        photosphere_adb shell run-as "$ANDROID_APP_ID" mkdir -p "$(dirname "$device_path")"
        photosphere_adb shell run-as "$ANDROID_APP_ID" cp "$staged" "$device_path"
        photosphere_adb shell rm -f "$staged" >/dev/null 2>&1 || true
        echo "Put the device's own $device_path back" >&2
        return 0
    fi
    photosphere_adb shell run-as "$ANDROID_APP_ID" rm -f "$device_path" >/dev/null 2>&1 || true
    echo "Removed $device_path, which the device did not have before this scenario" >&2
}

#
# Copies a directory of the app's files directory onto this machine. A whole tree rather than one file, because a database is a
# directory: a scenario that checks what the app wrote reads it with the CLI, and the CLI needs the whole `.db` folder. It goes through
# `tar` on the device and adb's stdout, because `adb pull` cannot reach private storage at all.
# Usage: android_save_sandbox_dir <dir_under_files> <local_dir>
#
android_save_sandbox_dir() {
    local device_dir="$1"
    local local_dir="$2"
    photosphere_android_prepare_for_seeding || return 1

    if ! photosphere_adb shell run-as "$ANDROID_APP_ID" test -d "files/$device_dir" >/dev/null 2>&1; then
        echo "The device has no files/$device_dir to save" >&2
        return 1
    fi
    mkdir -p "$local_dir"
    local tarball="$local_dir/sandbox-dir.tar"
    if ! photosphere_adb exec-out run-as "$ANDROID_APP_ID" tar c -C files "$device_dir" > "$tarball" 2>/dev/null; then
        echo "Could not read files/$device_dir off the device." >&2
        return 1
    fi
    if [ ! -s "$tarball" ]; then
        echo "files/$device_dir came back empty from the device." >&2
        return 1
    fi
    if ! tar xf "$tarball" -C "$local_dir" 2>/dev/null; then
        echo "Could not unpack files/$device_dir after copying it off the device." >&2
        return 1
    fi
    rm -f "$tarball"
}

#
# Brings the app's screen back to the front after it was sent to the background, without starting it again: the launcher intent resumes
# the app's task, so the core that was running goes on running. Wakes the screen first, so the activity comes up resumed rather than
# behind a sleeping screen. Claims the device first.
# Usage: android_bring_app_to_front
#
android_bring_app_to_front() {
    photosphere_android_claim_device || return 1
    photosphere_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    # The launcher intent with the flags new task and reorder to front, so the activity that exists is moved to the front and
    # no second copy of the activity, and so of the core, is made (without them the activity manager makes one).
    photosphere_adb shell am start -f 0x10020000 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$ANDROID_APP_ID/.MainActivity" >/dev/null
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

#
# Prints the absolute path, on the device, of a file in the app's settings directory. Usage: android_config_file_path <name>
#
android_config_file_path() {
    echo "/data/data/$ANDROID_APP_ID/$ANDROID_CONFIG_DIR_RELATIVE/$1"
}

#
# Puts a file from the host into the app's settings directory from outside the app, replacing one of the same name. Usage: android_put_config_file <host_file> <name>
#
android_put_config_file() {
    photosphere_android_prepare_for_seeding || return 1
    photosphere_android_put_file "$1" "$ANDROID_CONFIG_DIR_RELATIVE/$2"
}

#
# Prints a file of the app's settings directory as it stands on the device, or nothing when there is none. Usage: android_read_config_file <name>
#
android_read_config_file() {
    photosphere_adb exec-out run-as "$ANDROID_APP_ID" cat "$ANDROID_CONFIG_DIR_RELATIVE/$1" 2>/dev/null | grep -v ": No such file or directory$" || true
}

#
# Succeeds when a path under the app's files directory exists, whether a file or a directory. Usage: android_path_exists <relative_path_under_files>
#
android_path_exists() {
    photosphere_adb shell run-as "$ANDROID_APP_ID" test -e "files/$1"
}

#
# Writes a PNG of the claimed device's screen to a host path, with adb screencap. The app cannot do this itself, because a path it was
# given is a path on the phone. Fails when nothing was written or what was written is not a PNG.
# Usage: photosphere_platform_screenshot <output_path>
#
photosphere_platform_screenshot() {
    local output_path="$1"
    if [ -z "$ANDROID_SERIAL_CLAIMED" ]; then
        echo "No device is claimed, so there is no screen to capture." >&2
        return 1
    fi
    mkdir -p "$(dirname "$output_path")"
    if ! photosphere_adb exec-out screencap -p > "$output_path"; then
        echo "adb screencap failed on $ANDROID_SERIAL_CLAIMED" >&2
        return 1
    fi
    if [ "$(od -An -tx1 -N8 "$output_path" | tr -d ' \n')" != "89504e470d0a1a0a" ]; then
        echo "adb screencap on $ANDROID_SERIAL_CLAIMED wrote something that is not a PNG to $output_path" >&2
        return 1
    fi
}

#
# Waits until the background work service is no longer listed for the app, and returns non-zero when it is still listed after the
# time. Background syncing starts the service for as long as its loop runs and the page starts and stops that loop as the connection
# settles, so the service can still be listed for a moment after its loop has stopped. A service that something left running stays
# listed, so waiting tells the two apart.
# Usage: android_wait_for_background_service_gone [seconds]
#
android_wait_for_background_service_gone() {
    local seconds="$1"
    local waited=0
    while [ "$waited" -lt "$seconds" ]; do
        if ! photosphere_adb shell dumpsys activity services "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | grep -q "ZiggyKeepAliveService"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

#
# Makes the next download end as the user cancelling it. A phone hands a download to the system share sheet, which a test cannot tap, so
# the sheet's outcome is staged as cancelled. Usage: android_cancel_next_download <port>
#
android_cancel_next_download() {
    send_command "$1" stage-export '{"exportOutcome":"cancelled"}'
}

#
# The photo library helpers below are the names a scenario calls to give the app photos to take in, so one scenario body runs on every
# platform. A "library" is the folder a scenario puts its photos in and points automatic import at, and nothing else: on a phone watching
# the whole library would import somebody's photo collection, and a folder of the scenario's own is an album of its own.
#

#
# Prints where this run's photo library is: a directory of its own, named so a parallel run cannot collide with it.
# Usage: android_library_dir <name_prefix>
#
android_library_dir() {
    echo "/sdcard/DCIM/$1-$$"
}

#
# Clears out what an earlier run with this prefix left in the device library. A run killed outright never reaches its exit trap, and a
# photo it left would be imported by this one and throw its counts out. The files go first and the now-empty directories second, because
# a row removed while its file remains is put back by the next scan of the volume. Usage: android_library_sweep <name_prefix>
#
android_library_sweep() {
    local prefix="$1"
    photosphere_android_claim_device || return 1
    photosphere_adb shell "rm -f /sdcard/DCIM/$prefix-*/*" >/dev/null 2>&1 || true
    photosphere_adb shell "rmdir /sdcard/DCIM/$prefix-*" >/dev/null 2>&1 || true
    android_remove_media_matching "$prefix-" || true
}

#
# Puts a photo into the library. Usage: android_library_add <library> <host_file> <name>
#
android_library_add() {
    android_seed_media "$2" "$3" "$1"
}

#
# Takes the named photos out of the library and then the library itself, so a phone is left as it was found. Plain file deletes and an
# empty-directory removal, never a recursive one. Usage: android_library_remove <library> [name ...]
#
android_library_remove() {
    local library="$1"
    shift
    local photo_name
    for photo_name in "$@"; do
        android_remove_media "$photo_name" "$library" 2>/dev/null || true
    done
    photosphere_adb shell "rm -f $library/*" >/dev/null 2>&1 || true
    photosphere_adb shell "rmdir $library" >/dev/null 2>&1 || true
}

#
# Writes the automatic import settings so the import watches the library and nothing else. The library has to hold the named photo
# already, because the device only knows an album once something is in it. The other arguments are those of android_seed_auto_import_config.
# Usage: android_seed_library_auto_import_config <enabled true|false> <default_database_path or ""> <pause_ms> <library> <photo_name_in_it>
#
android_seed_library_auto_import_config() {
    local album_id
    album_id="$(android_media_album_id "$5")"
    if [ -z "$album_id" ]; then
        log_error "MediaStore did not file $5 under an album, so automatic import cannot be pointed at one."
        log_error "MediaStore row: $(android_media_store_row "$5" || echo "none")"
        return 1
    fi
    log_info "This scenario's photos are in album $album_id ($4)"
    android_seed_auto_import_config "$1" "$2" "$3" "$album_id"
}

#
# Prints how many originals the database named by the given directory name holds, or 0 when there is none yet. Read through run-as, which
# is the only way to see app-private storage. Usage: android_asset_count <database_dir_name>
#
android_asset_count() {
    photosphere_adb shell run-as "$ANDROID_APP_ID" ls "files/$1/asset" 2>/dev/null | tr -d '\r' | grep -c . || true
}

#
# Copies the database in the given directory of the app's files onto this machine, as android_save_sandbox_dir does. The destination is
# made by the copy. Usage: android_pull_database <dir_name> <local_dir>
#
android_pull_database() {
    android_save_sandbox_dir "$1" "$2"
}

#
# Sends the app to the background, as the user pressing Home. Usage: android_send_app_to_background
#
android_send_app_to_background() {
    photosphere_adb shell input keyevent KEYCODE_HOME
}

#
# Succeeds when what keeps the background work alive while the app is off screen is running: on a phone, the foreground service.
# Usage: android_background_work_running
#
android_background_work_running() {
    photosphere_adb shell dumpsys activity services "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | grep -q "ZiggyKeepAliveService"
}

#
# Prints what the background work has said about itself, for a failure to show. Usage: android_dump_background_diagnostics
#
android_dump_background_diagnostics() {
    photosphere_adb shell dumpsys activity services "$ANDROID_APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    photosphere_adb logcat -d -s AutoImportService:* 2>/dev/null | tail -60 || true
}

#
# Prints the lines the background work wrote since the last call to android_clear_background_log, which is where the sync loop says what
# it is doing with the app off screen. Usage: android_background_log
#
android_background_log() {
    photosphere_adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r'
}

#
# Forgets what the background work has said so far. Usage: android_clear_background_log
#
android_clear_background_log() {
    photosphere_adb logcat -c >/dev/null 2>&1 || true
}

#
# The log line that says automatic import was started, as this platform's app writes it. Usage: android_auto_import_started_log
#
android_auto_import_started_log() {
    echo "Starting automatic import."
}

#
# Turns the screen off, as the power button does, and back on. Usage: android_screen_off, android_screen_on
#
android_screen_off() {
    photosphere_adb shell input keyevent KEYCODE_POWER
}

android_screen_on() {
    photosphere_adb shell input keyevent KEYCODE_WAKEUP || return 1
    photosphere_adb shell input keyevent KEYCODE_MENU >/dev/null 2>&1 || true
}

#
# Claims the device this run uses. Usage: android_claim_device
#
android_claim_device() {
    photosphere_android_claim_device
}

#
# Succeeds when this run is on a real phone rather than an emulator. Needs a claimed device. Usage: android_is_real_device
#
android_is_real_device() {
    case "$ANDROID_SERIAL_CLAIMED" in
        emulator-*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

#
# Succeeds when the device is showing a lock screen. Usage: android_device_is_locked
#
android_device_is_locked() {
    photosphere_adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -q "mDreamingLockscreen=true"
}

#
# Fails, saying so, when the device shows a lock screen that cannot be dismissed from here. From Android 12 an app that is not in the
# foreground may not start a foreground service, and an app launched behind a lock screen is not in the foreground however visible it
# looks, so nothing would be imported or synced. An emulator, and a phone with no secure lock, are dismissed by waking the screen and
# swiping up, which is tried first. Usage: android_require_unlocked
#
android_require_unlocked() {
    if android_device_is_locked; then
        photosphere_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
        photosphere_adb shell input keyevent 82 >/dev/null 2>&1 || true
        photosphere_adb shell input swipe 540 1800 540 600 >/dev/null 2>&1 || true
        sleep 1
    fi
    if android_device_is_locked; then
        log_error "$ANDROID_SERIAL_CLAIMED is showing a lock screen that cannot be dismissed from here, so Android will refuse the foreground service and nothing will be imported or synced."
        log_error "Unlock the device and run this again."
        return 1
    fi
}

#
# Succeeds when the app's process is still alive. Usage: android_app_process_alive
#
android_app_process_alive() {
    photosphere_adb shell pidof "$ANDROID_APP_ID" >/dev/null 2>&1
}

#
# Copies a database in the app's files directory to a directory on the host, so the host's CLI can read what the app wrote. The
# directory is streamed out of the app's private storage as an archive, because adb cannot pull from it. The destination must not
# exist. Usage: android_fetch_database <relative_path_under_files> <host_dest>
#
android_fetch_database() {
    local rel_path="$1"
    local host_dest="$2"
    photosphere_android_claim_device || return 1
    mkdir -p "$host_dest" || return 1
    if ! photosphere_adb exec-out run-as "$ANDROID_APP_ID" tar -cf - -C "files/$rel_path" . | tar -xf - -C "$host_dest"; then
        echo "Could not copy files/$rel_path out of the app's storage" >&2
        return 1
    fi
    if [ -z "$(ls -A "$host_dest")" ]; then
        echo "files/$rel_path held nothing, so nothing was copied out of the app's storage" >&2
        return 1
    fi
}

#
# Succeeds when a file of the app's settings directory exists, even when it is empty. Usage: android_config_file_exists <name>
#
android_config_file_exists() {
    photosphere_adb shell run-as "$ANDROID_APP_ID" test -f "$ANDROID_CONFIG_DIR_RELATIVE/$1"
}

#
# Damages the device keychain the app keeps its secrets in, from outside the app, with the app stopped. The keychain is an encrypted
# preferences file that holds, beside the secrets, the keyset that seals them. The keyset is replaced with something that cannot be
# opened, which is what a damaged write leaves behind, so opening the keychain fails when the app next starts.
# Usage: android_damage_vault
#
android_damage_vault() {
    photosphere_android_claim_device || return 1
    local keychain_file="shared_prefs/photosphere_secure_store.xml"
    if ! photosphere_adb shell run-as "$ANDROID_APP_ID" test -f "$keychain_file"; then
        echo "No keychain file at $keychain_file to damage; the secret was never stored" >&2
        return 1
    fi
    printf '%s' "<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map><string name=\"__androidx_security_crypto_encrypted_prefs_key_keyset__\">00ff00ff</string></map>" \
        | photosphere_adb shell "run-as $ANDROID_APP_ID sh -c 'cat > $keychain_file'" || return 1
}

#
# The log line that says syncing was switched off, as this platform's app writes it. Usage: android_sync_stopped_log
#
android_sync_stopped_log() {
    echo "Stopping background syncing."
}

#
# Saves the settings files and the keychain of a real phone, so a scenario that changes them can hand them back instead of wiping the
# phone, which may hold somebody's imported library. The app is stopped so the settings written next are read at its next launch rather
# than fought over by a copy running with the phone's own. Usage: android_borrow_app_settings <local_dir>
#
android_borrow_app_settings() {
    local saved_dir="$1"
    mkdir -p "$saved_dir" || return 1
    android_save_app_data_file "files/config/config.yaml" "$saved_dir/config.yaml" || return 1
    android_save_app_data_file "files/config/databases.toml" "$saved_dir/databases.toml" || return 1
    android_save_app_data_file "shared_prefs/photosphere_secure_store.xml" "$saved_dir/secure-store.xml" || return 1
    photosphere_adb shell am force-stop "$ANDROID_APP_ID" >/dev/null 2>&1 || true
}

#
# Hands a real phone the settings android_borrow_app_settings saved, and takes the S3 credentials the scenario added with the keychain.
# The app offers no way to delete a secret, so this is the only way not to leave one on somebody's phone.
# Usage: android_return_app_settings <local_dir>
#
android_return_app_settings() {
    local saved_dir="$1"
    android_restore_app_data_file "files/config/config.yaml" "$saved_dir/config.yaml"
    android_restore_app_data_file "files/config/databases.toml" "$saved_dir/databases.toml"
    android_restore_app_data_file "shared_prefs/photosphere_secure_store.xml" "$saved_dir/secure-store.xml"
}

#
# Makes the app notice a settings file that was changed from outside it. The phone's background loops read the file again on every
# pass, so there is nothing to do. Usage: android_apply_settings_change
#
android_apply_settings_change() {
    return 0
}

#
# Has the app open the given database when it starts. A phone's background loops work on the database the settings name, and need no
# database open in the page, so there is nothing to do. Usage: android_open_database_on_launch <database_path>
#
android_open_database_on_launch() {
    return 0
}

#
# Succeeds when the background sync loop has said it ran a pass since android_clear_background_log. Usage: android_sync_pass_seen
#
android_sync_pass_seen() {
    android_background_log | grep -qE "Syncing \"|Not syncing"
}

#
# The log line that says automatic import was switched off, as this platform's app writes it. Usage: android_auto_import_stopped_log
#
android_auto_import_stopped_log() {
    echo "Stopping automatic import."
}

#
# Asks for the open database to be synced now. A phone's background sync loop pushes what an import added on its own, every pass, so there
# is nothing to ask for. Usage: android_request_sync <port>
#
android_request_sync() {
    return 0
}
