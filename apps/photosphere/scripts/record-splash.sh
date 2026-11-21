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
        # Up to 30 seconds: on a CI runner Xvfb once took more than 5, and the recording and the app were given an empty display.
        for _ in $(seq 1 300); do
            if [ -s "$display_file" ]; then
                break
            fi
            sleep 0.1
        done
        if [ ! -s "$display_file" ]; then
            echo "ERROR: Xvfb did not start a display within 30 seconds." >&2
            stop "$xvfb_pid"
            exit 1
        fi
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
        # The window is put at a known place and size (its outer edge at 112,20, its frontend 800x560, which with the title bar
        # and the menu bar fits a 1024x768 screen above the taskbar), and only the area around it is recorded: the title bar and
        # the menu bar are in the video, and the desktop's icons and the taskbar are not.
        ffmpeg -loglevel error -y -f gdigrab -framerate 30 -offset_x 96 -offset_y 0 -video_size 848x704 -i desktop \
            -t "$((seconds + 1))" -c:v libx264 -pix_fmt yuv420p "$output" &
        ffmpeg_pid=$!
        sleep 1
        "$app" "-geometry=800x560+112+20" &
        app_pid=$!
        wait "$ffmpeg_pid"
        stop "$app_pid"
        ;;
    macos)
        require ffmpeg
        # The app is the .app bundle, run by its executable so this script owns its process.
        executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$app/Contents/Info.plist")"
        # ffmpeg records the main display through AVFoundation, which names it "Capture screen 0" in its list of devices.
        # screencapture, which records through replayd, the system's screen recording service, hung on several Splash videos runs
        # waiting for replayd and wrote no recording.
        # Listing the devices, ffmpeg opens no input and exits with an error, which is not a failure here.
        devices="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
        screen="$(printf '%s\n' "$devices" | sed -n 's/.*\[\([0-9][0-9]*\)\] Capture screen 0$/\1/p' | head -n 1)"
        if [ -z "$screen" ]; then
            echo "ERROR: ffmpeg lists no \"Capture screen 0\" device to record the main display." >&2
            exit 1
        fi
        # The window's content is put at a known place and size, and only that area is kept: the title bar, whose close button is
        # red, the Dock and the rest of the desktop are not in the video. The menu bar is the system's, outside the window. The
        # area is in pixels, which on the 1024x768 display of CI's runners are points. A CI runner kept 13 frames a second, with gaps
        # of up to 466 milliseconds in the fade, where screencapture had kept a frame every 16 on the same app, both at the encoder's
        # default setting and at its fastest. The input's queue of captured frames is made larger, since ffmpeg drops frames when
        # it fills, and its warnings are printed so a recording that still drops frames says why. The frames are taken as bgr0, the
        # display's own layout: with none asked for, AVFoundation converted each to uyvy422, with no hardware scaler on the runner
        # ("IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver"), and the recording still kept under 13 frames a second.
        # The area kept starts four rows below the content's place, as on a CI runner the content started three rows lower than
        # placed and the bottom of the light title bar showed as a line across the top of the video. It is 552 rows tall, an even
        # number as the encoder needs, so it ends inside the content.
        ffmpeg -loglevel warning -y -f avfoundation -thread_queue_size 1024 -pixel_format bgr0 -capture_cursor 0 -framerate 30 \
            -i "$screen:none" \
            -t "$((seconds + 1))" -vf "crop=800:552:112:64" -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p "$output" &
        ffmpeg_pid=$!
        sleep 1
        "$executable" "-geometry=800x560+112+60" &
        app_pid=$!
        wait "$ffmpeg_pid"
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
        # The whole recording, from a moment before the app opens: the system's launch and the splash are part of what is checked.
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
        # The shell's own folder, which is always writable: on CI's emulator, just after it booted, screenrecord could not open a
        # file in /sdcard ("Operation not permitted").
        on_device="/data/local/tmp/record-splash-$$.mp4"
        # The app's launcher activity, once Android can find it: on CI's emulator, just after it booted and the app was installed,
        # monkey found no activity to start and failed. Up to 60 seconds.
        launcher=""
        for _ in $(seq 1 60); do
            launcher="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$package" | tail -n 1 | tr -d '\r')"
            case "$launcher" in
                "$package"/*)
                    break
                    ;;
            esac
            launcher=""
            sleep 1
        done
        if [ -z "$launcher" ]; then
            echo "ERROR: Android found no launcher activity for $package within 60 seconds of installing it." >&2
            exit 1
        fi
        adb shell screenrecord --time-limit "$((seconds + 1))" "$on_device" &
        record_pid=$!
        sleep 1
        # Started as the launcher starts it.
        adb shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$launcher" > /dev/null
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
