#!/usr/bin/env bash
#
# Answers one question with an exit code: is the Android emulator pool up?
#
#   exit 0   at least one pool emulator is running and on the LAN bridge
#   exit 1   none is
#
# It exists so nothing has to guess. "The pool is down" is easy to assume from a stale reading taken
# minutes earlier, and acting on that assumption is worse than not knowing: it turns into telling
# someone their emulators are gone when they are sitting there running, or skipping work that would
# have succeeded. A check that costs a second and cannot be out of date removes the excuse.
#
# `bun run emu:and:status` already returns 0 and 1 the same way, and is the right thing to read when
# a human wants the detail. It answers a wider question though: it counts every attached emulator on
# the bridge, including the single hand-testing one, so it reports ready when the pool is down and
# only the hand-testing emulator is up. This looks at the pool alone.
#
# On the bridge, not merely running, because a pool emulator without a 192.168.55.x address on wlan0
# cannot reach the host and no test can use it. Reporting that as up would be the same false
# reassurance in a different place.
#
# It also reports how much room each pool emulator has left, because an emulator can be running, on
# the bridge, and still useless: with a full /data the package manager refuses the install with
# INSTALL_FAILED_INSUFFICIENT_STORAGE, and a suite that does not check goes on testing whatever build
# was already there. That was invisible here until now, so "pool up" read as an all-clear while the
# results coming out of the suite were about somebody else's code.
#
# Free space does NOT change the exit code, which stays exactly what the two lines at the top say it
# is. Callers put that code in a condition to decide whether there is anything to run on at all, and
# an emulator short of space is a different problem with a different fix from an emulator that is not
# there.
#
# Read-only. It never starts, stops or changes anything: the pool belongs to whoever is at the
# keyboard.
#
# Usage:
#
#   bun run emu:and:pool:status
#       Print a summary line and exit 0 or 1.
#
#   bun run emu:and:pool:status -- --quiet
#       Exit code only, for use in a condition:
#           if bun run emu:and:pool:status -- --quiet; then ... fi
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The pool's AVD naming. Sourced rather than copied so a rename cannot leave this quietly matching
# nothing and reporting the pool down when it is up, which is the exact failure this script exists to
# prevent.
source "$REPO_DIR/apps/android-frontend/scripts/emulator-config.sh"

# The readings themselves: where adb is, whether a guest is on the bridge, and how much room it has
# left. Shared with the pool monitor and with emulator.sh's repair path, so the three cannot disagree
# about whether an emulator is usable. See emulator-status-lib.sh.
source "$REPO_DIR/apps/android-frontend/scripts/emulator-status-lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Suppress the summary line and answer with the exit code alone.
QUIET="false"

# How long to wait on any one adb call, how little free space is too little, and where that reading
# is taken. All three come from emulator-status-lib.sh, which is where the readings themselves live,
# so the number this reports low space against is the same one the repair path acts on.
ADB_TIMEOUT_SECONDS="$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS"
LOW_SPACE_MB="$EMULATOR_STATUS_LOW_SPACE_MB"
DEVICE_DATA_PATH="$EMULATOR_STATUS_DEVICE_DATA_PATH"

# One "<serial> <megabytes>" entry per pool emulator found below LOW_SPACE_MB. Filled while the
# emulators are walked and printed after the verdict, so the headline still comes first. A global
# rather than a local passed around, because an empty array cannot be expanded into a function's
# arguments under `set -u` without a guard that reads worse than this does.
LOW_SPACE_FOUND=()

#
# Prints a line per pool emulator in LOW_SPACE_FOUND, and nothing at all when every one of them has
# room. Silence is the normal case and is what says there is nothing here to act on.
#
report_low_space() {
    if [ "${#LOW_SPACE_FOUND[@]}" -eq 0 ]; then
        return 0
    fi

    local entry serial free_mb
    echo -e "${YELLOW}low on space${NC}: an install needs more room than these have left, and the package manager"
    echo -e "               refuses it with INSTALL_FAILED_INSUFFICIENT_STORAGE when it runs out:"
    for entry in "${LOW_SPACE_FOUND[@]}"; do
        serial="${entry%% *}"
        free_mb="${entry##* }"
        echo -e "  ${YELLOW}$serial${NC}  ${free_mb}MB free on $DEVICE_DATA_PATH (want at least ${LOW_SPACE_MB}MB)"
    done
    echo "               Free space on them, or restart the pool, before trusting a suite run."
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet)
                QUIET="true"
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Usage: bun run emu:and:pool:status -- [--quiet]" >&2
                exit 2
                ;;
        esac
    done

    local adb
    adb="$(emulator_status_adb)"
    if [ -z "$adb" ]; then
        if [ "$QUIET" = "false" ]; then
            echo -e "${RED}pool down${NC}: adb not found on PATH or in \${ANDROID_HOME:-\$HOME/Android/Sdk}/platform-tools"
        fi
        exit 1
    fi

    # Booted devices only. adb lists an emulator that is still starting as "offline", and one of those
    # is not something a test can use.
    local serials
    serials="$("$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }')"

    local serial avd guest free_mb
    local running=0
    local on_bridge=0

    for serial in $serials; do
        # Which AVD a serial is running is what makes it a pool emulator rather than the hand-testing
        # one. Asked of the emulator itself, because the serial alone does not say.
        avd="$(timeout "$ADB_TIMEOUT_SECONDS" "$adb" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r' || true)"
        case "$avd" in
            "$POOL_AVD_PREFIX"-*) ;;
            *) continue ;;
        esac

        running=$(( running + 1 ))

        guest="$(emulator_bridge_address "$serial")"
        if [ -n "$guest" ]; then
            on_bridge=$(( on_bridge + 1 ))
        fi

        # Asked of every running pool emulator, on or off the bridge. Being off the bridge is the
        # louder problem but it is not the only one, and an emulator brought back onto the bridge is
        # still unusable if it has no room.
        free_mb="$(emulator_free_mb "$serial")"
        if [ -n "$free_mb" ] && [ "$free_mb" -lt "$LOW_SPACE_MB" ]; then
            LOW_SPACE_FOUND+=("$serial $free_mb")
        fi
    done

    if [ "$on_bridge" -eq 0 ]; then
        if [ "$QUIET" = "false" ]; then
            if [ "$running" -eq 0 ]; then
                echo -e "${RED}pool down${NC}: no pool emulator is running"
            else
                echo -e "${RED}pool down${NC}: $running pool emulator(s) running, none on the LAN bridge"
            fi
            report_low_space
        fi
        exit 1
    fi

    if [ "$QUIET" = "false" ]; then
        # A partial pool is up as far as the exit code is concerned, since tests can run on what is
        # left, but it is said out loud rather than rounded up to "fine". Emulators disappear from
        # this pool by being killed for using too much memory, so a count that has dropped is the
        # first sign of that and is worth seeing.
        if [ "$on_bridge" -lt "$running" ]; then
            echo -e "${YELLOW}pool up${NC}: $on_bridge of $running pool emulator(s) on the LAN bridge"
        else
            echo -e "${GREEN}pool up${NC}: $on_bridge pool emulator(s) on the LAN bridge"
        fi
        report_low_space
    fi
    exit 0
}

main "$@"
