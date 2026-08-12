#!/usr/bin/env bash

# The one judgement of whether an emulator is healthy, in one file that everything asking the
# question sources.
#
# Source this; it is not a script anyone runs:
#   source "<repo>/apps/android-frontend/scripts/emulator-status-lib.sh"
#
# It defines functions and constants only and does nothing when sourced.
#
# Four places decide whether an emulator is usable: scripts/android-pool-status.sh (the exit code
# everything else reads), emulator-pool-monitor.sh (the watch display and the repair loop),
# emulator.sh's pool-repair (which indexes need restarting) and the smoke-test harness's own
# readiness check. Four copies of "healthy" drift apart, and the way they drift is silent: one of
# them starts calling an emulator fine while another calls it broken, and whichever a caller happens
# to have asked decides what happens to it.
#
# Every reading here is read-only. Nothing in this file starts, stops, reboots or reconfigures
# anything, and nothing in it runs sudo.

# How long any single adb call may take before it is abandoned. An emulator that has locked up stays
# listed by adb and accepts the connection while answering nothing, so a call to it never returns on
# its own and the caller inherits the hang instead of reporting it.
EMULATOR_STATUS_ADB_TIMEOUT_SECONDS=8

# The device path free space is measured at: the app's data volume, which is what an install and
# everything a test writes both land on. /data itself reports the whole partition, which is not what
# the package manager measures against.
EMULATOR_STATUS_DEVICE_DATA_PATH="/data/user/0"

# How little free space on that volume is too little to start a suite on.
#
# The debug APK is around 110MB and an install needs several times that: adb streams a copy into the
# staging area, the package manager keeps the installed copy, the native libraries are extracted
# beside it and dex optimisation writes more again. Every test then writes databases, imported photos
# and video thumbnails into app storage on top. An emulator with 400MB free has been seen to refuse
# the install outright, which is where this number comes from: it is the point at which an install is
# no longer safe to assume, not the point at which one is certain to fail.
EMULATOR_STATUS_LOW_SPACE_MB=1024

# The path to adb once it has been found, so the search is not repeated for every reading. Empty
# until the first call to emulator_status_adb, and set to a single space when the search failed, so
# a failed search is remembered rather than repeated on every call.
EMULATOR_STATUS_ADB_PATH=""

#
# Prints the path to adb, or nothing when it cannot be found. Looks on PATH first and then in the
# SDK, which are the two places every script in this repository looks.
#
emulator_status_adb() {
    if [ -n "$EMULATOR_STATUS_ADB_PATH" ]; then
        if [ "$EMULATOR_STATUS_ADB_PATH" != " " ]; then
            echo "$EMULATOR_STATUS_ADB_PATH"
        fi
        return 0
    fi

    if command -v adb >/dev/null 2>&1; then
        EMULATOR_STATUS_ADB_PATH="$(command -v adb)"
        echo "$EMULATOR_STATUS_ADB_PATH"
        return 0
    fi

    local sdk_adb="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
    if [ -x "$sdk_adb" ]; then
        EMULATOR_STATUS_ADB_PATH="$sdk_adb"
        echo "$EMULATOR_STATUS_ADB_PATH"
        return 0
    fi

    EMULATOR_STATUS_ADB_PATH=" "
    return 0
}

#
# Prints adb's own word for the state of the given serial: device, offline, unauthorized, or
# "missing" when adb does not list it at all. Never prints nothing, so a caller comparing the result
# against "device" cannot be reading an empty string it has to handle separately.
# Usage: emulator_adb_state <serial>
#
emulator_adb_state() {
    local serial="$1"
    local adb state

    adb="$(emulator_status_adb)"
    if [ -z "$adb" ]; then
        echo "missing"
        return 0
    fi

    # `|| true` on every reading in this file. A caller running under `set -e` would otherwise be
    # killed by an adb call that failed, and an adb call fails exactly when an emulator is in the
    # state these functions exist to report. The reading is the answer; a non-zero status from the
    # tool that took it is not.
    state="$(timeout "$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS" "$adb" devices </dev/null 2>/dev/null \
        | awk -v want="$serial" 'NR > 1 && $1 == want { print $2; exit }' || true)"
    if [ -z "$state" ]; then
        echo "missing"
        return 0
    fi
    echo "$state"
}

#
# Prints the guest's sys.boot_completed property: "1" once it has finished booting, "0" while it is
# still on its way, and nothing at all when the emulator did not answer.
#
# Every adb call in this file reads from /dev/null. `adb shell` consumes its standard input, and
# callers run these inside loops whose standard input is the list of devices, so without it the first
# emulator asked swallows the rest of the list and the caller sees one device.
# Usage: emulator_boot_completed <serial>
#
emulator_boot_completed() {
    local serial="$1"
    local adb booted

    adb="$(emulator_status_adb)"
    if [ -z "$adb" ]; then
        return 0
    fi

    booted="$(timeout "$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS" "$adb" -s "$serial" shell getprop sys.boot_completed \
        </dev/null 2>/dev/null | tr -d '\r' | head -1 || true)"
    if [ -n "$booted" ]; then
        echo "$booted"
    fi
}

#
# Prints one word about the guest's wifi, and the address with it when there is one:
#
#   address <a.b.c.d>  on the LAN bridge
#   no-carrier         wlan0 is down, so the wifi dropped rather than merely losing its lease
#   no-address         wlan0 is up but holds no 192.168.55.x address
#   no-answer          the emulator did not answer at all
#
# `ip addr show`, not `ip -4 addr show`. The -4 form prints nothing when the interface has no IPv4
# address, which is indistinguishable from the command having failed. Without the flag the link line
# is always printed, so an empty result means one thing only, and the line carries NO-CARRIER, which
# separates a dropped wifi from a lost lease.
# Usage: emulator_wlan_report <serial>
#
emulator_wlan_report() {
    local serial="$1"
    local adb wlan_output address

    adb="$(emulator_status_adb)"
    if [ -z "$adb" ]; then
        echo "no-answer"
        return 0
    fi

    wlan_output="$(timeout "$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS" "$adb" -s "$serial" shell ip addr show wlan0 \
        </dev/null 2>/dev/null || true)"
    if [ -z "$wlan_output" ]; then
        echo "no-answer"
        return 0
    fi

    address="$(printf '%s\n' "$wlan_output" | grep -o 'inet 192\.168\.55\.[0-9]*' | head -1 || true)"
    address="${address#inet }"
    if [ -n "$address" ]; then
        echo "address $address"
        return 0
    fi

    if printf '%s\n' "$wlan_output" | grep -q 'NO-CARRIER'; then
        echo "no-carrier"
        return 0
    fi
    echo "no-address"
}

#
# Prints the guest's address on the LAN bridge, or nothing when it has none. This is the one
# condition the smoke tests require, so an emulator this prints an address for is one the tests can
# use.
# Usage: emulator_bridge_address <serial>
#
emulator_bridge_address() {
    local report
    report="$(emulator_wlan_report "$1")"
    case "$report" in
        address\ *)
            echo "${report#address }"
            ;;
    esac
}

#
# Prints the megabytes free on the given emulator's app data volume, or nothing when it cannot be
# asked. Android's df reports 1K blocks by default and the fourth column is what is available.
# Usage: emulator_free_mb <serial>
#
emulator_free_mb() {
    local serial="$1"
    local adb available_kb

    adb="$(emulator_status_adb)"
    if [ -z "$adb" ]; then
        return 0
    fi

    available_kb="$(timeout "$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS" "$adb" -s "$serial" shell df "$EMULATOR_STATUS_DEVICE_DATA_PATH" \
        </dev/null 2>/dev/null | tr -d '\r' | awk 'NR > 1 { print $4; exit }' || true)"

    # Only a plain number is believed. A device that answered with an error, a warning or nothing at
    # all must not be reported as having some particular amount of room.
    case "$available_kb" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac
    echo "$(( available_kb / 1024 ))"
}

#
# Prints one word for the state of one emulator, worked out from every reading above:
#
#   healthy        booted, on the LAN bridge, and with room to install into
#   booting        answering, but the guest has not finished booting
#   not-answering  listed by adb, accepting the connection, answering nothing
#   off-bridge     booted, but wlan0 holds no 192.168.55.x address
#   low-space      booted and on the bridge, but too full for an install to be safe to assume
#   unreachable    adb does not list it as a device (offline, unauthorized, or gone)
#
# Every one of these is a verdict about one emulator and none of them changes anything. What a caller
# does with a word is the caller's business: the repair path restarts on some of them, the display
# colours a row on all of them, and the pool status check counts only the first as being on the
# bridge.
# Usage: emulator_health_verdict <serial>
#
emulator_health_verdict() {
    local serial="$1"
    local state booted report free_mb

    state="$(emulator_adb_state "$serial")"
    if [ "$state" != "device" ]; then
        echo "unreachable"
        return 0
    fi

    booted="$(emulator_boot_completed "$serial")"
    if [ -z "$booted" ]; then
        echo "not-answering"
        return 0
    fi
    if [ "$booted" != "1" ]; then
        echo "booting"
        return 0
    fi

    report="$(emulator_wlan_report "$serial")"
    case "$report" in
        no-answer)
            echo "not-answering"
            return 0
            ;;
        address\ *)
            ;;
        *)
            echo "off-bridge"
            return 0
            ;;
    esac

    # Last, because an emulator that is off the bridge is unusable whatever its free space says, and
    # reporting the quieter problem first would send whoever reads it after the wrong thing.
    free_mb="$(emulator_free_mb "$serial")"
    if [ -n "$free_mb" ] && [ "$free_mb" -lt "$EMULATOR_STATUS_LOW_SPACE_MB" ]; then
        echo "low-space"
        return 0
    fi

    echo "healthy"
}
