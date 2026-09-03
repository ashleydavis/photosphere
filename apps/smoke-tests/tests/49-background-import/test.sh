#!/bin/bash

# Automatic import carrying on while the app is not on screen, and while the screen is off.
#
# This is the whole point of the foreground service. The import used to be driven by a timer in the
# WebView, which the operating system throttles and then stops the moment the app is backgrounded:
# photos taken after that were backed up only when the app was next opened, and nothing anywhere said
# so. The loop now lives in a native service, and the two things this test does that test 47 does not
# are pressing HOME and turning the screen off.
#
# What it must NOT do is wait on app.log while the app is backgrounded. Log lines reach that file
# over a WebSocket from the WebView to the host bridge, and a backgrounded WebView may have that
# socket suspended, which is exactly the moment this test cares about. A test that waited on it would
# time out and report a working feature as broken. The two signals that keep working are the database
# on disk, read through `run-as`, and what dumpsys says about the service.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 49 "background-import"

# Android only. iOS cannot do this: a BGProcessingTask is scheduled by the system and the only way to
# force one is an lldb command against a running app, which this harness has no way to issue on
# Xcode 14.2. See IOS-NOT-COVERED.md beside this file.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: the background import is covered on Android only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The photos put into the device library, named so a parallel run cannot collide with them. All three
# are declared here so the exit trap can clean them up whether or not the test got that far.
FIRST_PHOTO_NAME="psphere-background-import-first-$$.jpeg"
BACKGROUNDED_PHOTO_NAME="psphere-background-import-backgrounded-$$.png"
SCREEN_OFF_PHOTO_NAME="psphere-background-import-screen-off-$$.jpg"

# The database automatic import makes for itself, and the directory inside it holding one file per
# original. Counting those is how this test finds out what was imported without asking the app.
DEFAULT_DATABASE_DIR="files/photosphere-default"
ASSET_DIR="$DEFAULT_DATABASE_DIR/asset"

# How long to wait for a photo to be taken in while the app is off screen. The gap between passes
# defaults to 30 seconds, so this allows for several of them plus the import itself.
IMPORT_TIMEOUT_SECONDS=240

#
# How many originals the app's database holds right now, or 0 when there is no database yet.
#
# Read through run-as, which is the only way to see app-private storage, and stripped of carriage
# returns, which adb adds to every line.
#
asset_count() {
    adb shell run-as "$APP_ID" ls "$ASSET_DIR" 2>/dev/null | tr -d '\r' | grep -c . || true
}

#
# Waits until the app's database holds at least the given number of originals.
#
# This is the assertion the whole test rests on, and it deliberately asks the device rather than the
# app: the app is backgrounded, or the screen is off, at every point this is called.
#
wait_for_asset_count() {
    local expected="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$IMPORT_TIMEOUT_SECONDS" ]; do
        local actual
        actual="$(asset_count)"
        if [ "${actual:-0}" -ge "$expected" ]; then
            log_success "The app's database holds $actual original(s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "The app's database never reached $expected original(s); it holds $(asset_count)"
    adb shell run-as "$APP_ID" ls -R "$DEFAULT_DATABASE_DIR" 2>/dev/null | tr -d '\r' | head -40 || true
    adb logcat -d -s AutoImportService:* 2>/dev/null | tail -40 || true
    return 1
}

#
# True when the foreground service is running.
#
auto_import_service_running() {
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"
}

# Removes the photos from the device library and puts the screen back on however the test ends. A
# screen left off poisons every test after it on that emulator, so it is restored on every path out,
# including a failure part way through the screen-off case.
on_exit() {
    local exit_code=$?
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    "${PLATFORM}_remove_media" "$FIRST_PHOTO_NAME" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$BACKGROUNDED_PHOTO_NAME" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$SCREEN_OFF_PHOTO_NAME" 2>/dev/null || true
    stop_app "$APP_PORT" "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

# Wipe everything the app has stored on the device, so this starts with no databases and no settings.
# The app creating its own database is part of what the background import has to do.
"${PLATFORM}_reset_app_state" || exit 1

# Sweep up anything a previous run of this test left behind. A run killed outright never reaches its
# exit trap, and a photo it left would be imported by this one and throw its counts out.
"${PLATFORM}_remove_media_matching" "psphere-background-import-" || true

# The first photo goes in before the app starts, so it is part of the library the first pass walks.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$FIRST_PHOTO_NAME" || exit 1

# Grant the photo permission from outside the app. The system dialog cannot be tapped by a test, and
# the app's own request resolves straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission, for the same reason. The service this test is about cannot post
# its notification without it, and the app asks for it as the toggle goes on.
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Switch automatic import on through the settings card, which is the only thing the user does.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The app hands the loop to the native side, which is what makes the rest of this test possible.
wait_for_log "$TMP_DIR" "Starting automatic import." || exit 1

# The first photo has to arrive, and the database it arrives in has to be one the app made for
# itself. Everything after this point happens with the app off screen, so this is the last thing the
# test learns from the app's own log.
wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

if ! auto_import_service_running; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported once the app leaves the screen."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service is running"

FIRST_COUNT="$(asset_count)"
if [ "${FIRST_COUNT:-0}" -lt 1 ]; then
    log_error "The first photo was reported as imported but the database holds $FIRST_COUNT original(s)."
    exit 1
fi

# Open the database and leave it open for the rest of the test.
#
# This is what makes the last step mean something. The gallery is filled by messages announcing each
# photo as it is imported, and those are delivered to whatever is listening at the time: while the
# app is off screen there is nothing listening, and nothing replays them afterwards. So a gallery
# opened after the app comes back would be right for the wrong reason, having loaded everything from
# disk. Opened before, it has to be brought up to date on its own.
send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 120 || exit 1

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets" 60 || exit 1

# Send the app to the background. From here the WebView's timers are throttled and then stopped, and
# its socket to the host bridge may be suspended, so nothing below reads app.log until the app is
# back on screen.
log_info "Sending the app to the background"
adb shell input keyevent KEYCODE_HOME || exit 1
sleep 2

# A photo taken while the app is not on screen. This is the one the old WebView loop never saw.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-2.png" "$BACKGROUNDED_PHOTO_NAME" || exit 1

wait_for_asset_count 2 || exit 1

if ! auto_import_service_running; then
    log_error "The foreground service stopped while the app was backgrounded, so the import above cannot be relied on to happen again."
    exit 1
fi
log_info "The foreground service is still running with the app off screen"

# Now with the screen off, which is the harder case: a foreground service keeps the process alive but
# does not by itself keep the CPU awake, which is what the service's wake lock is for.
log_info "Turning the screen off"
adb shell input keyevent KEYCODE_POWER || exit 1
sleep 2

"${PLATFORM}_seed_media" "$REPO_DIR/test/test.jpg" "$SCREEN_OFF_PHOTO_NAME" || exit 1

wait_for_asset_count 3 || exit 1

log_info "Turning the screen back on"
adb shell input keyevent KEYCODE_WAKEUP || exit 1
adb shell input keyevent KEYCODE_MENU >/dev/null 2>&1 || true
sleep 2

# Back to the app. The gallery has to hold all three, which is what proves the photos taken while it
# was away are in the database it opens rather than merely on disk somewhere.
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

# Wait for a pass to find all three already imported before opening the database.
#
# The counting above asks the filesystem, and an original is written to disk before its record is
# committed to the database, so a count of files can run ahead of what the gallery would load. That
# is not a fault in what is being tested: the photo is imported either way, and the count is still
# the right signal while the app is off screen, because it is the only one that keeps working there.
# It does mean the last step has to wait for the import to have finished rather than merely started,
# and a pass reporting three as "already there" is exactly that: the database has three records, not
# three files. Without this the gallery loaded two and the test failed on a photo that was imported
# a second later.
# The gallery has to catch up on its own, with nobody opening the database again.
#
# It was open throughout, and the two photos taken in while the app was away were announced to a
# WebView that was not running to hear it. Nothing replays those, so a gallery holding all three can
# only have reloaded: coming back to the screen is what does it. Without that the gallery goes on
# showing the one photo it held when the user left, however many have been backed up since, and the
# only way to see the truth is to know to open the database again.
#
# What is asserted is the count the gallery ends up showing, not the reload that gets it there, and
# the difference matters. Two earlier attempts at this line were both wrong:
#
# Waiting for an import pass to report all three as "already there" first walked the log cursor past
# everything below, because that line arrives after the reload, so a run where the app did everything
# right still failed.
#
# Waiting for the reload itself to report three assets was wrong in a subtler way. The counting above
# asks the filesystem, and a photo's file is written before its record is committed, so the app can
# come back while the third photo is a file and not yet a record. The reload then correctly loads two,
# the third is committed a moment later and arrives live, and the gallery reaches three having never
# reloaded three. Insisting on the stricter line failed a working app.
#
# Three in the gallery is the whole of what this test is about, and it cannot happen without the
# reload: the photo taken in while the app was off screen was announced to a WebView that was not
# running to hear it, nothing replays that, and a later pass reports it as already there rather than
# announcing it again. So a gallery that reaches three has been reloaded, which is the thing being
# proven.
wait_for_log "$TMP_DIR" "Gallery loaded: 3 assets" 240 || exit 1

# Switching automatic import off stops the import, and leaves the service up for syncing.
#
# The service hosts both loops and the two features are switched on separately, so it stops when
# NEITHER is on and not before. Syncing is on by default and this test has opened a database, which
# is what gives the sync loop something to push, so this first toggle must not take the service down:
# doing so would stop background syncing for somebody who only switched automatic import off.
#
# The settings card is still on screen from when the toggle was switched on: nothing in this test
# closed the configuration dialog, and it is drawn over whatever page the app is on rather than
# belonging to one. Asking for it again would do nothing at all, because the dialog is already open,
# and the card would not be built again, so the line saying it had read its settings would never come
# and this would wait for it until it gave up.
send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Stopping automatic import." || exit 1

sleep 3
if ! auto_import_service_running; then
    log_error "The foreground service stopped when automatic import was switched off, taking background syncing down with it. They are switched on separately and only both being off may stop it."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service is still running for syncing, with automatic import switched off"

# Now with syncing switched off as well, nothing is left to run: no service, and with it no
# notification.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Stopping background syncing." || exit 1

STOPPED=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! auto_import_service_running; then
        STOPPED=1
        break
    fi
    sleep 1
done

if [ "$STOPPED" -ne 1 ]; then
    log_error "The foreground service is still running with both automatic import and syncing switched off. Its notification stays up and the phone keeps working for nothing."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service stopped once neither automatic import nor syncing was on"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 49 passed: background-import"
