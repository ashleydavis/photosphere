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

# How long android_host_address waits for a bridge-attached emulator's wlan0 address to come back
# before it concludes the emulator is not on the bridge at all.
#
# The emulated wifi association drops and re-associates on its own under load, and wlan0 loses its
# 192.168.55.x address for the few seconds that takes (the guest re-DHCPs, which is visible as
# repeated DHCPREQUESTs from one emulator in the host dnsmasq log). A single sample taken inside
# that window reads as "not on the bridge" on an emulator that is on it, which is the one answer
# this must never give: the 10.0.2.2 it would fall back to is dead here, so the app is launched at
# an address it can never reach and burns both of its 120s readiness attempts before failing. The
# outages seen have healed well inside this window, and waiting a few seconds to launch costs far
# less than the 240s a wrong answer costs.
ANDROID_HOST_ADDRESS_WAIT_SECONDS=30

# The pool's AVD and tap names, from the one file that defines them. Sourced rather than copied: the
# harness has to recognise a pool emulator so it leaves a hand-testing one alone, and a duplicated
# literal would silently stop matching the day it was renamed, quietly reinstalling over somebody's
# own emulator.
source "$ANDROID_FRONTEND_DIR/scripts/emulator-config.sh"

#
# Prints one serial per line for every attached real device, and nothing when only emulators are
# attached. Deliberately ignores "offline" and "unauthorized" entries, which would otherwise be
# selected and then fail confusingly.
#
# A local emulator is always called "emulator-<port>" by adb, so anything else attached is a real
# device. A device reached over the network (`adb connect`) is called "<host>:<port>" and so counts as
# a real device here, which is what it is.
#
# This is the harness's copy of hardware_targets in apps/android-frontend/scripts/run-android.sh,
# which selects a deploy target by the same rule for the same reason. Written out again rather than
# shared because that script deliberately keeps clear of the harness's environment (ANDROID_SERIAL
# binding, log_info, APP_ID from common.sh).
#
android_hardware_devices() {
    adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1 }'
}

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
# A plugged-in real device is accepted before any of that is asked. The emulator LAN bridge exists to
# give an emulated guest a route to the host it otherwise has no way to reach, and a phone on the same
# physical LAN as the host already has one. Demanding the bridge would refuse a run on the very device
# that needs it least.
#
#
# Refuses the whole run when the machine has almost no memory left, before anything is built or
# installed.
#
# This is the mechanical part of stopping 2026-08-09 happening again. Five pool emulators hold 6.0 to
# 6.7GB each under a suite run, and the third Android run that day was started onto a machine already
# carrying twelve other lanes and a degraded pool. Every one of the five emulators was killed with
# SIGSEGV, and no rule stopped the run starting because rules are advice and this is a precondition.
#
# It skips silently where /proc/meminfo does not exist, which is every non-Linux host, and where the
# figure cannot be read as a number: refusing a run on a reading nobody could take would be worse
# than the risk it guards against.
#
# PHOTOSPHERE_MIN_AVAILABLE_MB overrides the limit, and is named in the refusal so whoever reads it
# can decide for themselves.
#
android_require_headroom() {
    local limit available
    limit="${PHOTOSPHERE_MIN_AVAILABLE_MB:-4096}"

    if [ ! -f /proc/meminfo ]; then
        return 0
    fi

    available="$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo)"
    case "$available" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac

    if [ "$available" -lt "$limit" ]; then
        log_error "This machine has ${available}MB of memory available and this run needs at least ${limit}MB."
        log_error "Starting an Android suite onto a machine with no headroom is what killed all five pool"
        log_error "emulators on 2026-08-09. Wait for the other runs to finish, or raise the limit with"
        log_error "PHOTOSPHERE_MIN_AVAILABLE_MB if you are certain."
        exit 1
    fi
}

#
# Warns, without refusing, when fewer of the pool's emulators are on the LAN bridge than the pool is
# supposed to have, and names the command that puts them back.
#
# A warning and not a refusal, because a run on a partial pool is legitimate: it is slower, not wrong.
# It deliberately does not repair anything either. A test run that started restarting the machine's
# emulators would be doing it underneath every other run using them.
#
android_warn_degraded_pool() {
    local serial avd index
    local present=" "
    local missing=""

    for serial in $(android_pool_devices); do
        avd="$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
        present="$present${avd#$POOL_AVD_PREFIX-} "
    done

    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        case "$present" in
            *" $index "*)
                ;;
            *)
                missing="$missing $index"
                ;;
        esac
    done

    if [ -z "$missing" ]; then
        return 0
    fi

    log_info "The pool is short of emulators: index(es)$missing are not on the LAN bridge, out of $PHOTOSPHERE_EMULATOR_COUNT."
    log_info "This run will use what is there and take longer for it. To bring them back:"
    log_info "  bun run --filter=android-frontend emu:pool:repair"
}

android_require_ready() {
    local hardware_devices

    android_require_headroom

    hardware_devices="$(android_hardware_devices)"
    if [ -n "$hardware_devices" ]; then
        log_info "Real device(s) attached, so the run will use them rather than the emulator pool:"
        echo "$hardware_devices" | sed 's/^/  /'
        return 0
    fi

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

    android_warn_degraded_pool
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
# Prints the devices this run may use, one per line.
#
# A plugged-in real device wins over everything else, for the reason run-android.sh gives about
# choosing a deploy target: the reason to have one attached is to test on it. Note what that costs. A
# run that would have spread itself over five pool emulators becomes a run on one phone, so the whole
# Android suite takes considerably longer while a phone is plugged in. Unplug it, or name the
# emulators in PHOTOSPHERE_ANDROID_DEVICES, to get the pool's parallelism back.
#
# With no real device attached, and when the pool is up, only the pool is used: a hand-testing
# emulator is left alone, because tests reinstall the app and wipe its data. Only when no pool
# emulator is running does this fall back to whatever bridge-ready device there is, which is what
# makes a single hand-started emulator work.
#
# PHOTOSPHERE_ANDROID_DEVICES (a space-separated serial list) overrides all of it.
#
android_device_slots() {
    if [ -n "${PHOTOSPHERE_ANDROID_DEVICES:-}" ]; then
        local serial
        for serial in $PHOTOSPHERE_ANDROID_DEVICES; do
            echo "$serial"
        done
        return 0
    fi

    local hardware_devices
    hardware_devices="$(android_hardware_devices)"
    if [ -n "$hardware_devices" ]; then
        echo "$hardware_devices"
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
# Whether a device can still reach this host, for the runner's health checks.
#
# On the LAN bridge this is a real measurement: the guest holds a 192.168.55.x address, the host
# answers on DEVICE_HEALTH_HOST, and a ping says whether the app could still talk to the control
# bridge. A run that has declared it has no bridge (PHOTOSPHERE_NO_LAN_BRIDGE=1, which the release
# workflow sets because its emulator is booted with no tap device) reaches the host at the NAT alias
# 10.0.2.2 instead, and nothing on the guest can ping DEVICE_HEALTH_HOST because that address exists
# nowhere. Probing it there measures nothing and fails every time, so it is not probed.
#
# Usage: android_can_reach_host <serial>
#
android_can_reach_host() {
    local serial="$1"
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        return 0
    fi
    timeout "$DEVICE_HEALTH_TIMEOUT_SECONDS" adb -s "$serial" shell \
        "ping -c 1 -W 1 $DEVICE_HEALTH_HOST" >/dev/null 2>&1
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

    # -crash-report-mode never and -no-metrics for the same reason emulator_launch_argv passes them:
    # the emulator's default is to open a modal dialog asking for consent to send any crash report
    # left by an earlier run, and to wait for a click before it starts the guest at all. Nothing is
    # watching this launch, so the wait below would run out with the emulator sitting there alive and
    # doing nothing. See apps/android-frontend/scripts/emulator.sh for what that cost once.
    nohup emulator -avd "$avd" -no-boot-anim -crash-report-mode never -no-metrics >/dev/null 2>&1 &

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
# A failed install stops the run. It used to be ignored: the exit code was never read and the stamp
# was written regardless, so a device that refused the install kept whatever build was already on it
# while reporting the new one's checksum. Every test that followed then ran another build's code and
# its result meant nothing, with no sign of it anywhere in the output. That is what
# INSTALL_FAILED_INSUFFICIENT_STORAGE looks like on a pool emulator whose /data has filled up: the
# suite carries on testing the previous build, and the only symptom is that the change under test
# appears not to exist. run.sh already treats a non-zero return here as fatal.
#
android_install() {
    if [ ! -f "$ANDROID_APK" ]; then
        log_error "APK not found at $ANDROID_APK (did android_build run?)"
        return 1
    fi
    log_info "Installing APK..."
    local install_output
    local install_status=0
    install_output="$(adb install -r "$ANDROID_APK" 2>&1)" || install_status=$?
    # The exit code is not trusted on its own. `adb install` has shipped versions that print
    # "Failure [INSTALL_FAILED_...]" and still exit 0, so the output decides it too: a successful
    # install prints "Success" on a line of its own and nothing else does.
    if [ "$install_status" -ne 0 ] || ! echo "$install_output" | grep -q '^Success$'; then
        log_error "Installing the APK on ${ANDROID_SERIAL:-this device} failed (exit $install_status). adb said:"
        echo "$install_output" | sed 's/^/  /'
        return 1
    fi
    echo "$install_output"
    # Record what is now on this device, so a run can tell whether the app it is about to test is
    # still its own build. Only reached once the install has actually succeeded, because a stamp
    # written after a failure is a lie the rest of the run believes. See android_ensure_apk.
    adb shell "echo $(android_apk_checksum) > $ANDROID_APK_STAMP" >/dev/null 2>&1 || true
}

# The APK checksum last computed, and the file identity it was computed from. Remembered because
# android_ensure_apk runs before every single test, and hashing 117MB of APK 43 times over reads
# roughly 5GB of it to answer the same question every time.
ANDROID_APK_CHECKSUM=""
ANDROID_APK_CHECKSUM_KEY=""

#
# Leaves a checksum of the APK this run built in ANDROID_APK_CHECKSUM.
#
# The answer comes back in a global rather than on stdout because a command substitution runs in a
# subshell, and a cache filled inside one dies with it: read through $(...) this would hash the APK
# every time and the cache would never hold anything.
#
# Cached against the APK's size and modification time rather than against nothing, so a rebuilt APK
# is hashed again. The build happens once, before any test, and under the build lock, so within a run
# the cache is filled by the first caller and answers every one after it.
#
android_read_apk_checksum() {
    local key
    # -c is GNU and -f is BSD. The iOS suite never calls this, but this file is sourced on macOS, so
    # both forms are tried rather than resting on which one exists.
    key="$(stat -c '%s %Y' "$ANDROID_APK" 2>/dev/null || stat -f '%z %m' "$ANDROID_APK" 2>/dev/null || echo "")"
    if [ -n "$key" ] && [ "$key" = "$ANDROID_APK_CHECKSUM_KEY" ] && [ -n "$ANDROID_APK_CHECKSUM" ]; then
        return 0
    fi
    ANDROID_APK_CHECKSUM="$(sha256sum "$ANDROID_APK" | cut -d' ' -f1)"
    ANDROID_APK_CHECKSUM_KEY="$key"
}

#
# Prints a checksum of the APK this run built.
#
android_apk_checksum() {
    android_read_apk_checksum
    printf '%s\n' "$ANDROID_APK_CHECKSUM"
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
    local installed
    # Sets ANDROID_APK_CHECKSUM in this shell, so the hash is computed on the first test of a run and
    # read from memory on the other 42.
    android_read_apk_checksum
    installed="$(adb shell cat "$ANDROID_APK_STAMP" 2>/dev/null | tr -d '\r\n')"
    if [ "$installed" = "$ANDROID_APK_CHECKSUM" ]; then
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
# A real device gets 127.0.0.1, and that is correct only because every host port a test serves is
# reversed onto the device with android_expose_host_port, so loopback on the phone is loopback on the
# host. Its branch comes before the polling below rather than after, because a phone never takes a
# 192.168.55.x address at all: that range is what the emulator bridge hands out, and a phone's address
# is on the developer's own LAN. Polling for one would wait out the full timeout to learn nothing and
# then fall through to the 10.0.2.2 NAT alias, which exists on an emulated guest and nowhere else.
#
# For an emulator the wlan0 address is polled for ANDROID_HOST_ADDRESS_WAIT_SECONDS rather than
# sampled once, because a bridge-attached emulator drops that address for a few seconds at a time when
# its wifi re-associates. Reading a flap as "not on the bridge" hands back the dead 10.0.2.2 alias and
# costs the caller both of its readiness attempts, so a missing address has to be given time to come
# back before it is believed. A genuinely NAT-only emulator has no wlan0 address to wait for and still
# ends up at 10.0.2.2, just later.
#
android_host_address() {
    if [ -n "${PHOTOSPHERE_ANDROID_TEST_HOST:-}" ]; then
        echo "$PHOTOSPHERE_ANDROID_TEST_HOST"
        return 0
    fi

    # A real device, before either of the emulator answers below. It has to come first even though
    # the no-bridge branch is also an early return: a phone reached with PHOTOSPHERE_NO_LAN_BRIDGE=1
    # set would otherwise be handed 10.0.2.2, which is QEMU's alias for the host and exists on an
    # emulated guest and nowhere else. Loopback is right here only because android_expose_host_port
    # reverses every host port a test serves onto the device.
    case "${ANDROID_SERIAL:-}" in
        ""|emulator-*)
            ;;
        *)
            echo "127.0.0.1"
            return 0
            ;;
    esac

    # A run that has declared it has no bridge is not waiting for one. The poll below exists to ride
    # out a bridge-attached emulator's wifi flap, and where PHOTOSPHERE_NO_LAN_BRIDGE=1 says there is
    # no bridge there is no flap to ride out and no address that could ever appear: the wait runs to
    # its full length and ends at 10.0.2.2 every single time.
    #
    # It is not free. This function is called on every app launch, and the release workflow, which
    # sets that flag, paid the full 30 seconds 43 times in one run: 21 and a half minutes of a 39
    # minute job, and the whole of the workflow's slowdown from 18 minutes to 40. Every test's
    # duration in that run was its old duration plus an exact multiple of 30 seconds.
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        echo "10.0.2.2"
        return 0
    fi

    # Every message here goes to stderr: this function's stdout is the address its caller captures,
    # so anything else written there would be read as part of it.
    local waited=0
    while true; do
        if adb shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
            if [ "$waited" -gt 0 ]; then
                log_info "wlan0 had no LAN address for ${waited}s; it came back, so the emulator is on the bridge after all." >&2
            fi
            echo "192.168.55.1"
            return 0
        fi
        if [ "$waited" -ge "$ANDROID_HOST_ADDRESS_WAIT_SECONDS" ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$waited" -gt 0 ]; then
        log_info "wlan0 never took a 192.168.55.x address in ${waited}s; treating this as a NAT-only emulator." >&2
    fi
    echo "10.0.2.2"
}

#
# Makes a port the host is listening on reachable from the device at the address android_host_address
# prints.
#
# On a real device that means `adb reverse`: the phone has no route to the host's loopback, and its
# own LAN address for the host is not what android_host_address hands out, so the port has to be
# tunnelled through adb to make 127.0.0.1 on the device mean this host. On an emulator it is a no-op,
# because the guest already reaches the host directly, at 192.168.55.1 over the LAN bridge or at
# 10.0.2.2 under user-mode NAT.
#
# Usage: android_expose_host_port <port>
#
android_expose_host_port() {
    local port="$1"
    case "${ANDROID_SERIAL:-}" in
        ""|emulator-*)
            return 0
            ;;
    esac
    adb reverse "tcp:$port" "tcp:$port" >/dev/null
    log_info "Reversed host port $port onto ${ANDROID_SERIAL}, so the device reaches it at 127.0.0.1:$port"
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
# The directory pushed test photos go into on the device, which is where a camera puts them.
#
ANDROID_MEDIA_DIR="/sdcard/DCIM/Camera"

#
# Puts a photo into the device's photo library, from outside the app.
#
# Two steps, and both are needed: pushing the file only puts bytes on the filesystem, and MediaStore
# is a database that knows nothing about them until it is told. `cmd media rescan` is not available
# on this emulator image (there is no "media" service), so the scan goes through the provider's own
# scan_file method, which is. Whichever is used has to be confirmed against the image the pool runs
# rather than assumed, because the available route differs by API level.
#
# Usage: android_seed_media <host_file> <remote_name>
#
android_seed_media() {
    local host_src="$1"
    local remote_name="$2"
    local remote_path="$ANDROID_MEDIA_DIR/$remote_name"

    adb shell mkdir -p "$ANDROID_MEDIA_DIR" >/dev/null 2>&1 || true
    adb push "$host_src" "$remote_path" >/dev/null || return 1

    local scan_result
    scan_result="$(adb shell content call --uri content://media/external/file --method scan_file --arg "$remote_path" 2>&1 | tr -d '\r')"
    if ! echo "$scan_result" | grep -q "Result:"; then
        log_error "MediaStore would not scan $remote_path: $scan_result"
        return 1
    fi

    # The scan returning a result is not the same as the photo being in MediaStore, and the
    # difference is what made test 47 fail on CI for two runs while passing here. On the API 33
    # emulator the workflow uses, scan_file answered `Result:` as it always does and then routed the
    # insert to the internal volume, which refuses anything outside the system media directories:
    # `Requested path /storage/emulated/0/DCIM/Camera/... doesn't appear under [/system/media, ...]`
    # in the device log, from ModernMediaScanner. The row was never written, the app's query over the
    # external volume found nothing, automatic import had nothing to import, and the test waited out
    # its three minutes against a library the harness had said it had seeded. Asking the row for
    # itself is the only answer that means what the log line claims.
    if ! android_media_store_has "$remote_name"; then
        # Scanning the volume rather than the file leaves no room for the path to be resolved to the
        # wrong volume, because the volume is what is named. Only reached when the per-file scan did
        # not take, so the usual path is unchanged and this costs nothing on an image where it works.
        adb shell content call --uri content://media/external --method scan_volume >/dev/null 2>&1 || true

        if ! android_media_store_has "$remote_name"; then
            # The row is printed when there is one, because "not indexed" and "indexed as something
            # the app does not read" are different faults with the same symptom, and the row is what
            # tells them apart.
            log_error "MediaStore does not hold $remote_path as an image or a video, so automatic import will never see it. The scan said: $scan_result"
            log_error "MediaStore row: $(android_media_store_row "$remote_name" || echo "none")"
            return 1
        fi
    fi

    log_info "Put '$remote_name' into the device photo library"
}

#
# Prints MediaStore's row for a photo, by the name it was seeded under, or nothing when there is
# none. Asked of the external volume, which is the collection the app reads.
#
# media_type is in the projection because the app does not ask for every file: it selects
# MEDIA_TYPE IN (image, video), so a row indexed as a plain file is one the app will never see. A
# check that only asked whether the name was present would call that seeded and be wrong in exactly
# the way this whole helper exists to catch.
# Usage: android_media_store_row <remote_name>
#
android_media_store_row() {
    local remote_name="$1"
    adb shell content query --uri content://media/external/file --projection _id:media_type:volume_name \
        --where "\"_display_name='$remote_name'\"" 2>&1 | tr -d '\r' | grep "^Row:"
}

#
# Whether MediaStore holds the photo as media the app can import: present, and typed as an image (1)
# or a video (3) rather than as an untyped file.
# Usage: android_media_store_has <remote_name>
#
android_media_store_has() {
    local remote_name="$1"
    android_media_store_row "$remote_name" | grep -qE "media_type=(1|3)"
}

#
# Removes a photo this test put into the device photo library, so the next run starts clean.
# Usage: android_remove_media <remote_name>
#
android_remove_media() {
    local remote_name="$1"
    adb shell rm -f "$ANDROID_MEDIA_DIR/$remote_name" >/dev/null 2>&1 || true
    adb shell content delete --uri content://media/external/file --where "_display_name='$remote_name'" >/dev/null 2>&1 || true
}

#
# Refuses the app the photo library permission, from outside the app, in a way that answers the next
# request without a dialog.
#
# Revoking alone is not enough: the next request would put the system dialog up, and a test cannot tap
# it. The user-fixed flag is what the system sets when a user chooses "Don't allow" and means it, and
# a request for a user-fixed permission comes straight back as denied. Which permissions to refuse
# depends on the device's API level, exactly as the app's own request does.
#
# Usage: android_refuse_media_permission
#
android_refuse_media_permission() {
    local sdk
    sdk="$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"

    local permissions
    if [ "${sdk:-0}" -ge 33 ]; then
        permissions="android.permission.READ_MEDIA_IMAGES android.permission.READ_MEDIA_VIDEO"
    else
        permissions="android.permission.READ_EXTERNAL_STORAGE"
    fi

    local permission
    for permission in $permissions; do
        adb shell pm revoke "$APP_ID" "$permission" >/dev/null 2>&1 || true

        local result
        result="$(adb shell pm set-permission-flags "$APP_ID" "$permission" user-fixed 2>&1 | tr -d '\r')"
        if [ -n "$result" ]; then
            log_error "Could not mark $permission as refused on ${ANDROID_SERIAL:-this device}: $result"
            return 1
        fi
    done

    log_info "Refused the photo library permission, as a user who chose \"Don't allow\""
}

#
# Removes every photo whose name starts with the given prefix from the device photo library.
#
# This is for the start of a test rather than the end of one: a run killed outright never reaches its
# exit trap, and the photo it left behind would be imported by the next run and throw its counts out.
# Safe to do because a test holds its emulator under a lock for its whole run, so nothing else is
# using the library at the time.
#
# Usage: android_remove_media_matching <name_prefix>
#
android_remove_media_matching() {
    local prefix="$1"
    adb shell "rm -f $ANDROID_MEDIA_DIR/$prefix*" >/dev/null 2>&1 || true
    adb shell content delete --uri content://media/external/file --where "_display_name LIKE '$prefix%'" >/dev/null 2>&1 || true
}

#
# Whether a photo is still in the device photo library.
# Usage: android_media_exists <remote_name>
#
android_media_exists() {
    local remote_name="$1"
    local result
    result="$(adb shell content query --uri content://media/external/file --projection _id --where "_display_name='$remote_name'" 2>&1 | tr -d '\r')"
    echo "$result" | grep -q "_id="
}

#
# Grants the app the photo library permission, from outside the app, so no permission dialog has to
# be tapped. Which permission to grant depends on the device's API level, exactly as the app's own
# request does.
# Usage: android_grant_media_permission
#
android_grant_media_permission() {
    local sdk
    sdk="$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"

    if [ "${sdk:-0}" -ge 33 ]; then
        adb shell pm grant "$APP_ID" android.permission.READ_MEDIA_IMAGES >/dev/null 2>&1 || true
        adb shell pm grant "$APP_ID" android.permission.READ_MEDIA_VIDEO >/dev/null 2>&1 || true
    else
        adb shell pm grant "$APP_ID" android.permission.READ_EXTERNAL_STORAGE >/dev/null 2>&1 || true
    fi

    log_info "Granted the photo library permission from outside the app"
}

#
# Clears the app's stored data once a test has finished with the device, so nothing a test wrote is
# still on the emulator when the next one starts.
#
# Every test already clears this on its way in, which is what keeps tests from reading each other's
# state. Doing it on the way out as well is about the emulator rather than the tests: whatever the
# last test wrote otherwise sits in the guest filesystem until something else happens to run there,
# and an emulator is shared, long-lived and shut down by nobody. Databases, imported photos and
# video thumbnails are not small.
#
# Deliberately quiet and deliberately unable to fail. This runs after a test's result has already
# been decided, so a device that has gone offline or an app that was never installed must not turn a
# passing test into a failing one, and there is nothing here worth a line in the runner's output.
#
android_clean_after_test() {
    adb shell pm clear "$APP_ID" >/dev/null 2>&1 || true
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
