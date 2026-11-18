#!/usr/bin/env bash

# Starts a built app and records the screen from before it opens until after its splash screen has faded out. See record-splash.md.

set -euo pipefail

usage() {
    echo "Usage: record-splash.sh --platform <linux|windows|macos|ios|android> --app <path> --output <video> [--seconds <n>] [--package <id>]" >&2
    exit 2
}

platform=""
app=""
output=""
seconds=12
package=""
while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            platform="$2"
            shift 2
            ;;
        --app)
            app="$2"
            shift 2
            ;;
        --output)
            output="$2"
            shift 2
            ;;
        --seconds)
            seconds="$2"
            shift 2
            ;;
        --package)
            package="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done
if [ -z "$platform" ] || [ -z "$app" ] || [ -z "$output" ]; then
    usage
fi
if [ ! -e "$app" ]; then
    echo "ERROR: there is no app at $app" >&2
    exit 1
fi
mkdir -p "$(dirname "$output")"

# Fails naming the command when it is not installed.
require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "ERROR: record-splash.sh needs $1, which is not on PATH." >&2
        exit 1
    fi
}

# Stops a process this script started, and does not complain when it has already ended.
stop() {
    kill "$@" 2> /dev/null || true
    wait "$@" 2> /dev/null || true
}

case "$platform" in
    linux)
        require Xvfb
        require ffmpeg
        # A display of its own, which Xvfb picks and writes to a file, so a run never takes a display another one is using.
        display_file="$(mktemp)"
        Xvfb -displayfd 3 -screen 0 1280x1000x24 -nolisten tcp 3> "$display_file" > /dev/null 2>&1 &
        xvfb_pid=$!
        for _ in $(seq 1 50); do
            if [ -s "$display_file" ]; then
                break
            fi
            sleep 0.1
        done
        display=":$(cat "$display_file")"
        rm -f "$display_file"
        ffmpeg -loglevel error -y -f x11grab -framerate 30 -video_size 1280x1000 -i "$display" -t "$((seconds + 1))" \
            -c:v libx264 -pix_fmt yuv420p "$output" &
        ffmpeg_pid=$!
        sleep 1
        # A theme setting of its own, so the app never asks the session bus for the system's theme, which waits 25 seconds where
        # the bus has no desktop portal.
        DISPLAY="$display" ZIGGY_THEME="${ZIGGY_THEME:-dark}" "$app" &
        app_pid=$!
        wait "$ffmpeg_pid"
        stop "$app_pid"
        stop "$xvfb_pid"
        ;;
    windows)
        require ffmpeg
        ffmpeg -loglevel error -y -f gdigrab -framerate 30 -i desktop -t "$((seconds + 1))" -c:v libx264 -pix_fmt yuv420p \
            -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" "$output" &
        ffmpeg_pid=$!
        sleep 1
        "$app" &
        app_pid=$!
        wait "$ffmpeg_pid"
        stop "$app_pid"
        ;;
    macos)
        require screencapture
        # screencapture records the main display for the number of seconds given. The app is the .app bundle, run by its executable
        # so this script owns its process.
        executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$app/Contents/Info.plist")"
        screencapture -v -V "$((seconds + 1))" "$output" &
        capture_pid=$!
        sleep 1
        "$executable" &
        app_pid=$!
        wait "$capture_pid"
        stop "$app_pid"
        ;;
    ios)
        require xcrun
        require jq
        # The simulator ZIGGY_IOS_SIMULATOR names, otherwise one already booted, otherwise the first available iPhone.
        simulator="${ZIGGY_IOS_SIMULATOR:-}"
        if [ -z "$simulator" ]; then
            simulator="$(xcrun simctl list devices available --json | jq -r '[.devices[][] | select(.state == "Booted")][0].udid // empty')"
        fi
        if [ -z "$simulator" ]; then
            simulator="$(xcrun simctl list devices available --json | jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid // empty')"
        fi
        if [ -z "$simulator" ]; then
            echo "ERROR: there is no available iPhone simulator." >&2
            exit 1
        fi
        xcrun simctl boot "$simulator" 2> /dev/null || true
        xcrun simctl bootstatus "$simulator" -b > /dev/null
        bundle_id="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Info.plist")"
        xcrun simctl terminate "$simulator" "$bundle_id" 2> /dev/null || true
        xcrun simctl install "$simulator" "$app"
        xcrun simctl io "$simulator" recordVideo --codec h264 --force "$output" &
        record_pid=$!
        sleep 2
        xcrun simctl launch "$simulator" "$bundle_id" > /dev/null
        sleep "$seconds"
        # The recording is written out when it is interrupted.
        kill -INT "$record_pid"
        wait "$record_pid" || true
        xcrun simctl terminate "$simulator" "$bundle_id" 2> /dev/null || true
        ;;
    android)
        require adb
        if [ -z "$package" ]; then
            echo "ERROR: --package is needed for Android." >&2
            exit 1
        fi
        # ANDROID_SERIAL picks the device, as it does for adb itself.
        adb install -r "$app" > /dev/null
        adb shell am force-stop "$package"
        on_device="/sdcard/record-splash-$$.mp4"
        adb shell screenrecord --time-limit "$((seconds + 1))" "$on_device" &
        record_pid=$!
        sleep 1
        adb shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 > /dev/null
        wait "$record_pid"
        # screenrecord finishes writing the file a moment after it exits.
        sleep 1
        adb pull "$on_device" "$output" > /dev/null
        adb shell rm -f "$on_device"
        adb shell am force-stop "$package"
        ;;
    *)
        usage
        ;;
esac

if [ ! -s "$output" ]; then
    echo "ERROR: no video was recorded at $output" >&2
    exit 1
fi
echo "Recorded $output"
