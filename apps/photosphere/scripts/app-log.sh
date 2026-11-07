#!/usr/bin/env bash
#
# Prints the Photosphere App's log file from the device or computer the app runs on. See app-log.md.
#
# Usage:
#   app-log.sh --platform <linux|macos|windows|android|ios> [--target <adb serial or simulator udid>] [--errors] [--from-line <line number>] [--path]
#
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#
# The app's id on the desktop platforms, from the .app_id each native host passes to Ziggy, and its
# bundle identifier on macOS. The data directory is named after it.
#
DESKTOP_APP_ID="au.com.codecapers.photosphere"

#
# The app's bundle id on the iOS simulator, the one reset-ios.sh and the iOS smoke tests use.
#
IOS_BUNDLE_ID="au.com.codecapers.photosphere.ziggy"

usage() {
    echo "Usage: bun run app:log -- --platform <linux|macos|windows|android|ios> [--target <adb serial or simulator udid>] [--errors] [--from-line <line number>] [--path]" >&2
    exit 2
}

#
# Prints a message to stderr and exits 1.
#
fail() {
    echo "ERROR: $1" >&2
    exit 1
}

#
# Prints the newest log file name that matches the chosen kind (main or errors) from a listing of
# the log folder on stdin. The names carry their start time, so the last one in sorted order is the
# newest. Prints nothing when none matches.
#
newest_log_name() {
    local pattern='^photosphere-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.log$'
    if [ "$errors" = "true" ]; then
        pattern='^photosphere-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-errors\.log$'
    fi
    tr -d '\r' | grep -E "$pattern" | sort | tail -n 1 || true
}

#
# Prints the kind of log being read, for messages.
#
log_kind() {
    if [ "$errors" = "true" ]; then
        echo "errors log"
    else
        echo "main log"
    fi
}

#
# Prints the chosen log of a log folder on this computer: its path, the whole file or the file from
# a line onward. Usage: print_local_log <log folder>
#
print_local_log() {
    local logs_dir="$1"
    local name
    if [ ! -d "$logs_dir" ]; then
        fail "the log folder $logs_dir does not exist. Start the app first, or set PHOTOSPHERE_LOG_DIR to the folder the app was started with."
    fi
    name="$(ls -1 "$logs_dir" | newest_log_name)"
    if [ -z "$name" ]; then
        fail "there is no $(log_kind) in $logs_dir."
    fi
    if [ "$path_only" = "true" ]; then
        printf '%s\n' "$logs_dir/$name"
    else
        tail -n "+$from_line" "$logs_dir/$name"
    fi
}

#
# Prints the adb serial to read from: the one passed with --target when adb lists it as a device,
# otherwise the only device adb lists. It takes no device lock, so reading a log never holds up a
# test that is using a pool emulator.
#
android_serial() {
    local adb_command="$1"
    local serials count
    serials="$("$adb_command" devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    if [ -n "$target" ]; then
        if ! printf '%s\n' "$serials" | grep -qxF -- "$target"; then
            fail "adb does not list $target as an attached device. Attached devices: $(printf '%s' "${serials:-none}" | tr '\n' ' ')."
        fi
        printf '%s\n' "$target"
        return 0
    fi
    count="$(printf '%s' "$serials" | grep -c . || true)"
    if [ "$count" != "1" ]; then
        fail "expected exactly one attached Android device but found $count ($(printf '%s' "$serials" | tr '\n' ' ')). Pass --target <adb serial> to name one."
    fi
    printf '%s\n' "$serials"
}

#
# Prints the chosen log from the app's sandbox on an Android device. Every read goes through
# run-as, because the sandbox is readable only by the app itself.
#
print_android_log() {
    source "$SCRIPTS_DIR/android-common.sh"
    local adb_command="$ANDROID_HOME/platform-tools/adb"
    local serial logs_dir found name
    serial="$(android_serial "$adb_command")"
    logs_dir="${PHOTOSPHERE_LOG_DIR:-files}/logs"
    found="$("$adb_command" -s "$serial" exec-out run-as "$PHOTOSPHERE_ANDROID_APP_ID" ls -d "$logs_dir" 2>&1 | tr -d '\r' || true)"
    if [ "$found" != "$logs_dir" ]; then
        fail "could not find the log folder $logs_dir of $PHOTOSPHERE_ANDROID_APP_ID on $serial: $found"
    fi
    name="$("$adb_command" -s "$serial" exec-out run-as "$PHOTOSPHERE_ANDROID_APP_ID" ls -1 "$logs_dir" | newest_log_name)"
    if [ -z "$name" ]; then
        fail "there is no $(log_kind) in $logs_dir of $PHOTOSPHERE_ANDROID_APP_ID on $serial."
    fi
    if [ "$path_only" = "true" ]; then
        printf '%s\n' "$logs_dir/$name"
    else
        "$adb_command" -s "$serial" exec-out run-as "$PHOTOSPHERE_ANDROID_APP_ID" tail -n "+$from_line" "$logs_dir/$name"
    fi
}

#
# Prints the udid of the iOS simulator to read from: the one passed with --target, otherwise the
# only booted simulator. A physical device is refused, because reading its files needs a debugger
# session and devicectl needs a newer Xcode than this project uses.
#
ios_udid() {
    local booted count
    if [ -n "$target" ]; then
        if ! xcrun simctl list devices | grep -qF -- "($target)"; then
            fail "$target is not an iOS simulator. The app's log is read only from the iOS simulator, not from a physical device."
        fi
        printf '%s\n' "$target"
        return 0
    fi
    booted="$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p')"
    count="$(printf '%s' "$booted" | grep -c . || true)"
    if [ "$count" != "1" ]; then
        fail "expected exactly one booted iOS simulator but found $count ($(printf '%s' "$booted" | tr '\n' ' ')). Pass --target <simulator udid> to name one."
    fi
    printf '%s\n' "$booted"
}

#
# Prints the chosen log from the app's data container on the iOS simulator, which is a folder on
# this Mac.
#
print_ios_log() {
    local udid container
    udid="$(ios_udid)"
    if ! container="$(xcrun simctl get_app_container "$udid" "$IOS_BUNDLE_ID" data 2>/dev/null)"; then
        fail "$IOS_BUNDLE_ID is not installed on the simulator $udid."
    fi
    print_local_log "${PHOTOSPHERE_LOG_DIR:-$container/Library/Application Support/$IOS_BUNDLE_ID}/logs"
}

if [ $# -lt 1 ]; then
    usage
fi
platform=""
target=""
errors="false"
from_line="1"
path_only="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --platform|--target|--from-line)
            if [ $# -lt 2 ]; then
                echo "ERROR: $1 needs a value." >&2
                usage
            fi
            case "$1" in
                --platform)
                    platform="$2"
                    ;;
                --target)
                    target="$2"
                    ;;
                --from-line)
                    from_line="$2"
                    ;;
            esac
            shift 2
            ;;
        --errors)
            errors="true"
            shift
            ;;
        --path)
            path_only="true"
            shift
            ;;
        *)
            echo "ERROR: unknown argument '$1'." >&2
            usage
            ;;
    esac
done
if ! [[ "$from_line" =~ ^[1-9][0-9]*$ ]]; then
    fail "--from-line must be a positive whole number, not '$from_line'."
fi
case "$platform" in
    linux)
        print_local_log "${PHOTOSPHERE_LOG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$DESKTOP_APP_ID}/logs"
        ;;
    macos)
        print_local_log "${PHOTOSPHERE_LOG_DIR:-$HOME/Library/Application Support/$DESKTOP_APP_ID}/logs"
        ;;
    windows)
        if [ -z "${PHOTOSPHERE_LOG_DIR:-}" ] && [ -z "${LOCALAPPDATA:-}" ]; then
            fail "LOCALAPPDATA is not set, so the app's data directory cannot be found. Set LOCALAPPDATA or PHOTOSPHERE_LOG_DIR."
        fi
        print_local_log "${PHOTOSPHERE_LOG_DIR:-${LOCALAPPDATA:-}/$DESKTOP_APP_ID}/logs"
        ;;
    android)
        print_android_log
        ;;
    ios)
        print_ios_log
        ;;
    "")
        echo "ERROR: --platform is required." >&2
        usage
        ;;
    *)
        echo "ERROR: unknown platform '$platform' (expected linux, macos, windows, android or ios)." >&2
        usage
        ;;
esac
