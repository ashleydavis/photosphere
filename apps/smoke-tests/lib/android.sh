#!/bin/bash

# Android launcher for mobile smoke tests. Sourced by common.sh when PLATFORM=android.
# Drives an Android emulator (or attached device) entirely from the host via adb; the bridge
# captures the screen with `adb exec-out screencap`.
#
# android_prepare sets up the toolchain automatically (detects ANDROID_HOME, puts adb/emulator
# on PATH, finds a JDK 17, and boots an emulator if none is attached), so `bun run test:and`
# works without manual environment setup. The only prerequisite that cannot be auto-installed is
# a JDK 17 (AGP 8.0 fails on the JDK 21 Android Studio bundles); see ensure_jdk17.

# Path to the debug APK produced by assembleDebug.
ANDROID_APK="$ANDROID_FRONTEND_DIR/android/app/build/outputs/apk/debug/app-debug.apk"

# Where a device records the checksum of the APK currently installed on it. Lives outside the app's
# own storage, which android_cleanup wipes, so it survives a run's teardown and can still be trusted
# by the next one.
ANDROID_APK_STAMP="/data/local/tmp/psphere-apk.sha"

# The bridge script owns the definition of "ready" (emulator started + on the LAN bridge). run.sh
# gates on it so `status` and the test run never disagree about what ready means.
ANDROID_BRIDGE_SCRIPT="$ANDROID_FRONTEND_DIR/scripts/emulator.sh"

# The pool's AVD and tap names, from the one file that defines them. Sourced rather than copied: the
# harness has to recognise a pool emulator so it leaves a hand-testing one alone, and a duplicated
# literal would silently stop matching the day it was renamed, quietly reinstalling over somebody's
# own emulator.
source "$ANDROID_FRONTEND_DIR/scripts/emulator-config.sh"

#
# Fails the whole run immediately unless the emulator is started AND on the LAN bridge, by delegating
# to the bridge script's `status` (exit 0 = ready). Never boots, restarts, wipes, reboots, or changes
# any setting on the emulator: getting it ready is the human's job, not this script's.
#
# Only the two host-to-device LAN transfer tests need the bridge, and they check for it themselves
# (require_lan_bridge). A run that has declared it cannot have a bridge, and so skips those two, only
# needs the emulator started, so that is all this requires of it. Asking for the bridge in that case
# would gate the whole suite on something it does not use.
#
android_require_ready() {
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        log_info "Checking the emulator is started (PHOTOSPHERE_NO_LAN_BRIDGE=1, so the LAN bridge is not required)..."
        if ! adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit found ? 0 : 1 }'; then
            log_error "No started emulator or device is attached. test:and needs one."
            log_error "Start it yourself, then rerun. This script will not touch the emulator."
            exit 1
        fi
        return 0
    fi

    log_info "Checking the emulator is ready (started + on the LAN bridge)..."
    if ! "$ANDROID_BRIDGE_SCRIPT" status; then
        log_error "Emulator not ready (see above). test:and needs it started and on the LAN bridge."
        log_error "Start it and bring up the bridge yourself, then rerun. This script will not touch the emulator."
        exit 1
    fi
}

#
# Prints one serial per line for every attached device the run may use. These are the devices the run
# spreads its work over.
#
# That means devices on the LAN bridge, which is what the smoke tests require, except on a run that
# has declared it cannot have a bridge (PHOTOSPHERE_NO_LAN_BRIDGE=1): there a booted device is all
# there is to ask for. Without that exception the release workflow found no usable device and failed
# the whole suite, because its emulator is booted by an action that attaches no tap device, so no
# device ever holds a 192.168.55.x address. The two tests that genuinely need the bridge check for it
# themselves and skip (see require_lan_bridge); everything else reaches the host over NAT.
#
android_ready_devices() {
    local serial
    for serial in $(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
            echo "$serial"
        elif adb -s "$serial" shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
            echo "$serial"
        fi
    done
}

#
# Prints the emulators this run may use, one per line.
#
# When the pool is up, only the pool is used: a hand-testing emulator is left alone, because tests
# reinstall the app and wipe its data. Only when no pool emulator is running does this fall back to
# whatever bridge-ready device there is, which is what makes a single hand-started emulator work.
#
# PHOTOSPHERE_ANDROID_DEVICES (a space-separated serial list) overrides both.
#
android_device_slots() {
    if [ -n "${PHOTOSPHERE_ANDROID_DEVICES:-}" ]; then
        local serial
        for serial in $PHOTOSPHERE_ANDROID_DEVICES; do
            echo "$serial"
        done
        return 0
    fi

    local pool_devices
    pool_devices="$(android_pool_devices)"
    if [ -n "$pool_devices" ]; then
        echo "$pool_devices"
        return 0
    fi

    android_ready_devices
}

#
# Prints the bridge-ready emulators that belong to the test pool, one per line. A pool emulator is
# one running a cloned pool AVD, which is how it is told apart from a hand-started one.
#
android_pool_devices() {
    local serial avd
    for serial in $(android_ready_devices); do
        avd="$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
        case "$avd" in
            "$POOL_AVD_PREFIX"-*)
                echo "$serial"
                ;;
        esac
    done
}

#
# Binds the calling shell to one device. Every adb invocation in this file and in the tests is bare,
# and adb honours ANDROID_SERIAL from the environment, so this one export is what makes a worker's
# whole test run target its own emulator.
# Usage: android_export_device <serial>
#
android_export_device() {
    export ANDROID_SERIAL="$1"
}

#
# Returns 0 if the given Java home is a JDK 17 installation.
#
java_is_17() {
    local java_home="$1"
    [ -n "$java_home" ] && [ -x "$java_home/bin/java" ] && "$java_home/bin/java" -version 2>&1 | grep -q 'version "17'
}

#
# Ensures JAVA_HOME points at a JDK 17. The Android build (AGP 8.0) fails on JDK 21 (the version
# Android Studio bundles), so a JDK 17 is required. Honors an already-correct JAVA_HOME, then a
# PHOTOSPHERE_JDK17_HOME override, then searches common install locations. Fails with a clear
# install hint if none is found.
#
ensure_jdk17() {
    if java_is_17 "${JAVA_HOME:-}"; then
        log_info "Using JDK 17 at $JAVA_HOME"
        return 0
    fi
    local candidate
    for candidate in \
        "${PHOTOSPHERE_JDK17_HOME:-}" \
        /usr/lib/jvm/java-17-openjdk-amd64 \
        /usr/lib/jvm/java-17-openjdk \
        /usr/lib/jvm/temurin-17-jdk-amd64 \
        /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home \
        "$HOME"/.jdks/*17* \
        "$HOME"/.gradle/jdks/*17* \
        "$HOME"/.sdkman/candidates/java/17*; do
        if java_is_17 "$candidate"; then
            export JAVA_HOME="$candidate"
            log_info "Using JDK 17 at $JAVA_HOME"
            return 0
        fi
    done
    log_error "A JDK 17 is required to build the Android app (AGP 8.0 fails on the JDK 21 that"
    log_error "Android Studio bundles). Install one, e.g.:  sudo apt install openjdk-17-jdk"
    log_error "Or set PHOTOSPHERE_JDK17_HOME (or JAVA_HOME) to a JDK 17 install."
    return 1
}

#
# Sets up the Android toolchain environment so `bun run test:and` works without manual
# exports: detects the SDK (ANDROID_HOME), puts platform-tools and emulator on PATH, and selects
# a JDK 17. Honors values already set in the environment.
#
android_setup_env() {
    if [ -z "${ANDROID_HOME:-}" ]; then
        if [ -d "$HOME/Android/Sdk" ]; then
            export ANDROID_HOME="$HOME/Android/Sdk"
        elif [ -d "$HOME/Library/Android/sdk" ]; then
            export ANDROID_HOME="$HOME/Library/Android/sdk"
        fi
    fi
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
    if [ -n "${ANDROID_HOME:-}" ]; then
        export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
    fi
    ensure_jdk17
}

#
# Returns 0 if an emulator/device is attached and reporting "device" state.
#
android_device_attached() {
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'
}

#
# Sets up the environment, boots an emulator if none is attached, and waits for it to finish
# booting. The AVD is the first one found unless ANDROID_AVD is set.
#
android_prepare() {
    android_setup_env || return 1

    if ! command -v adb >/dev/null 2>&1; then
        log_error "adb not found. Install the Android SDK platform tools (or set ANDROID_HOME)."
        return 1
    fi

    # Already-attached devices report "device" state, which means they have finished booting, so
    # there is nothing to wait for. Checked before the boot path because the waits below target a
    # single implicit device and fail outright with "more than one device/emulator" when a pool of
    # them is attached.
    if android_device_attached; then
        log_info "$(adb devices | awk 'NR > 1 && $2 == "device"' | wc -l) device(s) already attached"
        return 0
    fi

    local avd
    avd="${ANDROID_AVD:-$(emulator -list-avds 2>/dev/null | head -1)}"
    if [ -z "$avd" ]; then
        log_error "No emulator attached and no AVD found. Create one in Android Studio's Device Manager."
        return 1
    fi
    log_info "No device attached; booting emulator '$avd' (left running for faster reruns)..."
    nohup emulator -avd "$avd" -no-boot-anim >/dev/null 2>&1 &

    log_info "Waiting for an Android device/emulator..."
    adb wait-for-device
    local booted=""
    local elapsed=0
    while [ "$elapsed" -lt 180 ]; do
        booted=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ "$booted" = "1" ]; then
            log_info "Android device booted"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_error "Android device did not finish booting within 180s"
    return 1
}

#
# Builds the web assets, syncs Capacitor, and assembles the debug APK.
#
android_build() {
    log_info "Building Android app..."
    (cd "$ANDROID_FRONTEND_DIR" && bun run sync)
    (cd "$ANDROID_FRONTEND_DIR/android" && ./gradlew assembleDebug)
}

#
# Installs (or reinstalls) the debug APK on the device.
#
android_install() {
    if [ ! -f "$ANDROID_APK" ]; then
        log_error "APK not found at $ANDROID_APK (did android_build run?)"
        return 1
    fi
    log_info "Installing APK..."
    adb install -r "$ANDROID_APK"
    # Record what is now on this device, so a run can tell whether the app it is about to test is
    # still its own build. See android_ensure_apk.
    adb shell "echo $(android_apk_checksum) > $ANDROID_APK_STAMP" >/dev/null 2>&1 || true
}

#
# Prints a checksum of the APK this run built.
#
android_apk_checksum() {
    sha256sum "$ANDROID_APK" | cut -d' ' -f1
}

#
# Reinstalls the app when the one on the device is not this run's build, and does nothing when it is.
#
# Every worktree builds an APK with the same applicationId, so two checkouts running their suites
# against the same emulators overwrite each other's install. Without this, a run's later tests
# silently execute another worktree's code and pass or fail for reasons that have nothing to do with
# it. The device's own lock is held while this runs, so the reinstall cannot land underneath a test.
#
# The stamp is the APK's sha recorded on the device at install time. Comparing bytes rather than
# timestamps or "did we build" flags means an unnoticed swap can never look like a match.
#
android_ensure_apk() {
    local installed expected
    expected="$(android_apk_checksum)"
    installed="$(adb shell cat "$ANDROID_APK_STAMP" 2>/dev/null | tr -d '\r\n')"
    if [ "$installed" = "$expected" ]; then
        return 0
    fi
    log_info "Another build is installed on ${ANDROID_SERIAL:-this device}; reinstalling this run's APK."
    android_install
}

#
# Prints the address the emulator/device uses to reach this host.
#
# A bridge-attached emulator (the LAN sharing setup, apps/android-frontend/scripts/emulator.sh)
# has a 192.168.55.x address on wlan0 and reaches the host at 192.168.55.1, where the 10.0.2.2 NAT
# alias is dead (the guest has no default route to it). A plain user-mode NAT emulator reaches the
# host at 10.0.2.2. Auto-detect from the guest's wlan0 address, overridable with
# PHOTOSPHERE_ANDROID_TEST_HOST (for example 127.0.0.1 for a physical device over `adb reverse`).
#
android_host_address() {
    if [ -n "${PHOTOSPHERE_ANDROID_TEST_HOST:-}" ]; then
        echo "$PHOTOSPHERE_ANDROID_TEST_HOST"
        return 0
    fi
    if adb shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
        echo "192.168.55.1"
    else
        echo "10.0.2.2"
    fi
}

#
# Launches the app in test mode pointing at the host control bridge.
# Usage: android_launch <port>
#
# The host address depends on how the emulator is networked (see android_host_address). The control
# bridge binds 0.0.0.0 so either address reaches it (see control-bridge.ts). `adb reverse` is still
# set for a physical device targeted via PHOTOSPHERE_ANDROID_TEST_HOST=127.0.0.1.
#
android_launch() {
    local port="$1"
    adb reverse "tcp:$port" "tcp:$port"

    local host
    host="$(android_host_address)"
    if [ "$host" = "192.168.55.1" ]; then
        log_info "Emulator is on the LAN bridge; pointing the app at the host at $host."
    fi

    adb shell am start -n "$APP_ID/.MainActivity" \
        --ez photosphereTestMode true \
        --es photosphereTestHost "$host" \
        --ei photosphereTestPort "$port"
}

#
# Force-stops the app and removes the port reverse.
# Usage: android_stop <port>
#
android_stop() {
    local port="$1"
    adb shell am force-stop "$APP_ID"
    if [ -n "$port" ]; then
        adb reverse --remove "tcp:$port" 2>/dev/null || true
    fi
}

#
# Seeds a database fixture into the app's private files directory (the native storage sandbox root
# resolved by getFilesDir / PathSandbox), so the embedded worker can read it via the host fs
# functions. The host path is pushed to a world-readable temp location, then copied into the app
# sandbox via run-as (the only way to write app-private storage; works because the debug build is
# debuggable).
# Usage: android_seed_database <host_fixture_dir> <relative_dest_under_files>
#
android_seed_database() {
    local host_src="$1"
    local rel_dest="$2"
    local base
    base="$(basename "$host_src")"
    local tmp_remote="/data/local/tmp/$base"

    # Each step is a single adb shell command (no shell operators), because `adb shell` re-splits the
    # remote command on spaces and mangles `sh -c "...&&..."` quoting. run-as runs in the app's data
    # directory, so the destination is relative to that (files/ is the getFilesDir sandbox root).
    adb shell rm -rf "$tmp_remote" >/dev/null 2>&1 || true
    adb push "$host_src" /data/local/tmp/ >/dev/null
    adb shell run-as "$APP_ID" rm -rf "files/$rel_dest"
    # Make the destination's parents, not just files/: a nested destination (test/dbs/50-assets)
    # otherwise fails the copy with "No such file or directory".
    adb shell run-as "$APP_ID" mkdir -p "files/$(dirname "$rel_dest")"
    adb shell run-as "$APP_ID" cp -r "$tmp_remote" "files/$rel_dest"
    adb shell rm -rf "$tmp_remote" >/dev/null 2>&1 || true
    log_info "Seeded database fixture '$base' into app sandbox at files/$rel_dest"
}

#
# Writes the app's databases.toml into its private files directory, registering the given databases
# and recent-database names.
#
# This is the mobile equivalent of a desktop smoke test pre-writing ~/.config/photosphere/databases.toml:
# the state goes in from outside the app, before it launches, rather than the app carrying a seeding
# command for the tests to call. The file is rendered on the host by lib/write-databases-config.ts,
# which uses the same node-api function the app itself writes the file through.
#
# Both arguments are JSON: the databases as an array of {name, path} (description optional), the
# recents as an array of names. An omitted recents argument writes an empty recents list.
# Usage: android_seed_databases_config '<databases json>' ['<recent names json>']
#
android_seed_databases_config() {
    local databases_json="$1"
    local recent_json="${2:-[]}"
    local tmp_local
    tmp_local="$(mktemp)"

    if ! DATABASES="$databases_json" RECENT="$recent_json" bun "$LIB_DIR/write-databases-config.ts" "$tmp_local"; then
        log_error "Could not render the app's database list (see the error above)."
        rm -f "$tmp_local"
        return 1
    fi

    # Pushed via the shared temp directory, because adb push cannot write app-private storage directly.
    adb push "$tmp_local" "/data/local/tmp/$DATABASES_CONFIG_FILE" >/dev/null
    adb shell run-as "$APP_ID" mkdir -p files
    adb shell run-as "$APP_ID" cp "/data/local/tmp/$DATABASES_CONFIG_FILE" "files/$DATABASES_CONFIG_FILE"
    adb shell rm -f "/data/local/tmp/$DATABASES_CONFIG_FILE" >/dev/null 2>&1 || true
    rm -f "$tmp_local"

    log_info "Wrote the app's database list to files/$DATABASES_CONFIG_FILE"
}

#
# Wipes everything the app has stored on the device: its storage sandbox (the seeded databases and
# databases.toml), the WebView's localStorage (the news feed and the generic config values) and the
# Keystore-backed keychain the secrets live in.
#
# This is what gives a test a deterministic start, and it replaces the app-side reset-config command.
# `pm clear` removes the app's whole data directory, so it reaches the WebView and keychain state no
# host-side file copy can, and it runs with the app stopped, so nothing can write state back
# underneath it. Call it BEFORE start_app.
#
android_reset_app_state() {
    local result
    result="$(adb shell pm clear "$APP_ID" 2>&1 | tr -d '\r')"
    # `pm clear` prints "Success" and exits 0; a failure is reported in its output, so the text is
    # what has to be checked. Failing here rather than carrying on is deliberate: a test that ran on
    # state left by an earlier one would pass or fail for reasons that have nothing to do with it.
    if [ "$result" != "Success" ]; then
        log_error "Could not clear the app's stored data on ${ANDROID_SERIAL:-this device}: $result"
        return 1
    fi
    log_info "Cleared the app's stored data (sandbox, WebView storage, keychain)"
}

#
# Removes a path under the app's private files directory (the storage sandbox root), so a test that
# creates fresh state at that path is rerunnable. No-op when the app is not installed yet.
# Usage: android_reset_path <relative_path_under_files>
#
android_reset_path() {
    local rel="$1"
    adb shell run-as "$APP_ID" rm -rf "files/$rel" >/dev/null 2>&1 || true
}

#
# Polls the app's private files directory until the given path exists and is non-empty (for a
# directory, until it lists at least one entry), or the wait times out. Used to observe a background
# task's effect on device storage (for example a partial-database prefetch copying thumbnails into
# the local replica), which the host cannot otherwise see. Returns 0 once present, non-zero on
# timeout.
# Usage: android_wait_for_file <relative_path_under_files>
#
android_wait_for_file() {
    local rel="$1"
    local ticks=$((DEFAULT_WAIT_TIMEOUT * POLL_TICKS_PER_SECOND))
    while [ "$ticks" -gt 0 ]; do
        if adb shell run-as "$APP_ID" ls "files/$rel" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
    done
    return 1
}

#
# Removes everything a run leaves on the device: the databases seeded into the app's storage sandbox
# and whatever the run imported into them, plus the fixture copies pushed through the shared temp
# directory. The app stays installed, so the next run does not pay for a reinstall.
#
# Without this the seeded fixtures and imported assets accumulate run after run until the device is
# out of storage and the next install fails with INSTALL_FAILED_INSUFFICIENT_STORAGE.
#
android_cleanup() {
    adb shell run-as "$APP_ID" rm -rf files >/dev/null 2>&1 || true
    adb shell rm -rf /data/local/tmp/50-assets >/dev/null 2>&1 || true
    log_info "Cleared the app's data from the device"
}
