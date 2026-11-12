#!/usr/bin/env bash

# Switches syncing on in the Photosphere App on an Android device and sets how many seconds it waits between sync passes, by
# writing the sync table of the app's config.toml. For manual tests that wait on a sync. See set-sync-interval-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"
source "$PHOTOSPHERE_ANDROID_TOOLS_DIR/emulator-config.sh"

adb_command="$ANDROID_HOME/platform-tools/adb"

usage="Usage: set-sync-interval-android.sh [--target <adb serial>] <seconds>"
serial="${PHOTOSPHERE_ANDROID_TARGET:-}"
seconds=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            serial="$2"
            shift 2
            ;;
        -*)
            echo "$usage" >&2
            exit 2
            ;;
        *)
            if [ -n "$seconds" ]; then
                echo "$usage" >&2
                exit 2
            fi
            seconds="$1"
            shift
            ;;
    esac
done
if ! [[ "$seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "$usage" >&2
    echo "ERROR: <seconds> must be a whole number greater than 0, got: '$seconds'." >&2
    exit 2
fi

photosphere_android_pick_device "$serial"
serial="$PHOTOSPHERE_ANDROID_SERIAL"

app_id="$PHOTOSPHERE_ANDROID_APP_ID"
if ! "$adb_command" -s "$serial" shell pm path "$app_id" | grep -q '^package:'; then
    echo "ERROR: Photosphere is not installed on $serial. Run 'bun run android' first." >&2
    exit 1
fi

# The app writes its settings when it closes, so a running app would put the old ones back over these.
"$adb_command" -s "$serial" shell am force-stop "$app_id"

# The file as it stands, minus its sync table, which runs from the header line "[sync]" to the next line starting with "[". After a
# reset there is no file yet, and nothing is kept.
existing=""
if "$adb_command" -s "$serial" shell run-as "$app_id" test -f files/config.toml; then
    existing="$("$adb_command" -s "$serial" shell run-as "$app_id" cat files/config.toml | tr -d '\r' | {
        in_table="false"
        while IFS= read -r line; do
            if [ "$in_table" = "false" ] && [ "$line" = "[sync]" ]; then
                in_table="true"
                continue
            fi
            if [ "$in_table" = "true" ]; then
                if [[ "$line" == \[* ]]; then
                    in_table="false"
                else
                    continue
                fi
            fi
            printf '%s\n' "$line"
        done
    })"
fi

{
    if [ -n "$existing" ]; then
        printf '%s\n' "$existing"
    fi
    printf '[sync]\nenabled = true\nonly_on_wifi = true\npause_between_runs_ms = %s\n' "$((seconds * 1000))"
} | "$adb_command" -s "$serial" shell "run-as $app_id sh -c 'mkdir -p files && cat > files/config.toml'"

written="$("$adb_command" -s "$serial" shell run-as "$app_id" cat files/config.toml | tr -d '\r')"
if ! printf '%s\n' "$written" | grep -q "^pause_between_runs_ms = $((seconds * 1000))$"; then
    echo "ERROR: the app's config.toml on $serial does not hold the new sync setting after writing it. It holds:" >&2
    printf '%s\n' "$written" >&2
    exit 1
fi
echo "Syncing is on in Photosphere on $serial, every $seconds second(s)."
