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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Suppress the summary line and answer with the exit code alone.
QUIET="false"

# How long to wait on any one adb call. An emulator that has locked up does not answer at all, and
# without this the check inherits its hang instead of reporting it.
ADB_TIMEOUT_SECONDS=8

#
# Prints the path to adb, or nothing when it cannot be found. Looks on PATH first and then in the SDK,
# the same two places emulator.sh looks.
#
adb_path() {
    if command -v adb >/dev/null 2>&1; then
        command -v adb
        return 0
    fi

    local sdk_adb="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
    if [ -x "$sdk_adb" ]; then
        echo "$sdk_adb"
    fi
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
    adb="$(adb_path)"
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

    local serial avd guest
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

        guest="$(timeout "$ADB_TIMEOUT_SECONDS" "$adb" -s "$serial" shell ip addr show wlan0 2>/dev/null | tr -d '\r' | awk '/inet 192\.168\.55\./ { print $2 }' || true)"
        if [ -n "$guest" ]; then
            on_bridge=$(( on_bridge + 1 ))
        fi
    done

    if [ "$on_bridge" -eq 0 ]; then
        if [ "$QUIET" = "false" ]; then
            if [ "$running" -eq 0 ]; then
                echo -e "${RED}pool down${NC}: no pool emulator is running"
            else
                echo -e "${RED}pool down${NC}: $running pool emulator(s) running, none on the LAN bridge"
            fi
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
    fi
    exit 0
}

main "$@"
