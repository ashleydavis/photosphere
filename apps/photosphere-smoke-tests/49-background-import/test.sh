#!/bin/bash

# Automatic import carrying on while the app is not on screen, and while the screen is off.
#
# This is the whole point of the foreground service. The import used to be driven by a timer in the web view, which the operating
# system throttles and then stops the moment the app is backgrounded: photos taken after that were backed up only when the app was next
# opened, and nothing anywhere said so. The loop now runs in the core under a foreground service, and the two things this scenario does
# that the foreground auto-import scenario does not are pressing HOME and turning the screen off.
#
# What it must NOT do is wait on app.log while the app is backgrounded. Log lines reach that file from the web view, and a backgrounded
# web view may be suspended, which is exactly the moment this scenario cares about. The two signals that keep working are the database
# on disk, read through `run-as`, and what dumpsys says about the service.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 49 "background-import"

# Not on iOS. iOS cannot do this: a BGProcessingTask is scheduled by the system and the only way to force one is an lldb command
# against a running app, which this harness has no way to issue on Xcode 14.2.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: the background import is covered on Android and the desktop only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The photos put into the library, named so a parallel run cannot collide with them. All three are declared here so the exit trap can
# clean them up whether or not the scenario got that far.
FIRST_PHOTO_NAME="psphere-background-import-first-$$.jpeg"
BACKGROUNDED_PHOTO_NAME="psphere-background-import-backgrounded-$$.png"
SCREEN_OFF_PHOTO_NAME="psphere-background-import-screen-off-$$.jpg"

# The library this scenario's photos go in, which is a folder of its own. On a phone that is an album of its own, because the device
# files an item under the directory it sits in.
#
# That is what makes this scenario run on a real phone as well as an emulator. Switching automatic import on watches the whole photo
# library, and a phone's library is somebody's photo collection. The counts below are of what the app's database holds, so every one of
# those would be counted, and the scenario would be waiting for three originals while thousands arrived. Pointing automatic import at
# this library alone means the only photos it can take in are the ones this scenario put there, on any device.
LIBRARY_PREFIX="psphere-background-import"
LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"

# The gap between passes, seeded short so the scenario is not waiting out the thirty second default several times over while the app is
# off screen.
PASS_GAP_MS=5000

# The database automatic import makes for itself. Counting the originals in it is how this scenario finds out what was imported without
# asking the app.
DEFAULT_DATABASE_DIR_NAME="photosphere-default"

# How long to wait for a photo to be taken in while the app is off screen. The gap between passes defaults to 30 seconds, so this allows
# for several of them plus the import itself.
IMPORT_TIMEOUT_SECONDS=240

#
# How many originals the app's database holds right now, or 0 when there is no database yet.
#
# Read from outside the app, which is the only way to see its storage on a phone.
#
asset_count() {
    "${PLATFORM}_asset_count" "$DEFAULT_DATABASE_DIR_NAME"
}

#
# Waits until the app's database holds at least the given number of originals.
#
# This is the assertion the whole scenario rests on, and it deliberately asks the platform rather than the app: the app is backgrounded,
# or the screen is off, at every point this is called.
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
    "${PLATFORM}_dump_background_diagnostics"
    return 1
}

# Removes the photos from the library and puts the screen back on however the scenario ends. A screen left off poisons every scenario
# after it on that emulator, so it is restored on every path out, including a failure part way through the screen-off case.
on_exit() {
    local exit_code=$?
    "${PLATFORM}_screen_on" >/dev/null 2>&1 || true

    # The library goes too, so a phone is left as it was found.
    "${PLATFORM}_library_remove" "$LIBRARY" "$FIRST_PHOTO_NAME" "$BACKGROUNDED_PHOTO_NAME" "$SCREEN_OFF_PHOTO_NAME" 2>/dev/null || true

    cleanup_apps "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

# Wipe everything the app has stored, so this starts with no databases and no settings. The app creating its own database is part of
# what the background import has to do.
"${PLATFORM}_reset_app_state" || exit 1

# Sweep up anything a previous run of this scenario left behind. A run killed outright never reaches its exit trap, and a photo it left
# would be imported by this one and throw its counts out.
"${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1

# The first photo goes in before the app starts, so it is part of the library the first pass walks.
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$FIRST_PHOTO_NAME" || exit 1

# Automatic import is switched OFF here and pointed at that library. Switching it ON is what the scenario does through the settings card
# below; the card reads these settings and writes back what it read with the switch flipped, so the library survives. No default
# database path is seeded, because the app creating its own is part of what is under test.
"${PLATFORM}_seed_library_auto_import_config" "false" "" "$PASS_GAP_MS" "$LIBRARY" "$FIRST_PHOTO_NAME" || exit 1

# Grant the photo permission from outside the app. The system dialog cannot be tapped by a script, and the app's own request resolves
# straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission, for the same reason. The service this scenario is about cannot post its notification without it, and
# the app asks for it as the toggle goes on.
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Switch automatic import on through the settings card, which is the only thing the user does.
send_command "$APP_PORT" menu '{"action":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The app hands the loop to the core, which is what makes the rest of this scenario possible.
wait_for_log "$TMP_DIR" "$("${PLATFORM}_auto_import_started_log")" || exit 1

# The first photo has to arrive, and the database it arrives in has to be one the app made for itself. Everything after this point
# happens with the app off screen, so this is the last thing the scenario learns from the app's own log.
wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

if ! "${PLATFORM}_background_work_running"; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported once the app leaves the screen."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi
log_info "The foreground service is running"

FIRST_COUNT="$(asset_count)"
if [ "${FIRST_COUNT:-0}" -lt 1 ]; then
    log_error "The first photo was reported as imported but the database holds $FIRST_COUNT original(s)."
    exit 1
fi

# Open the database and leave it open for the rest of the scenario.
#
# This is what makes the last step mean something. The gallery is filled by messages announcing each photo as it is imported, and those
# are delivered to whatever is listening at the time: while the app is off screen there is nothing listening, and nothing replays them
# afterwards. So a gallery opened after the app comes back would be right for the wrong reason, having loaded everything from disk.
# Opened before, it has to be brought up to date on its own.
send_command "$APP_PORT" menu '{"action":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 120 || exit 1

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets" 60 || exit 1

# Send the app to the background. From here the web view's timers are throttled and then stopped, and its connection to the host may be
# suspended, so nothing below reads app.log until the app is back on screen.
log_info "Sending the app to the background"
"${PLATFORM}_send_app_to_background" || exit 1
sleep 2

# A photo taken while the app is not on screen. This is the one the old web view loop never saw.
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-2.png" "$BACKGROUNDED_PHOTO_NAME" || exit 1

wait_for_asset_count 2 || exit 1

if ! "${PLATFORM}_background_work_running"; then
    log_error "The foreground service stopped while the app was backgrounded, so the import above cannot be relied on to happen again."
    exit 1
fi
log_info "The foreground service is still running with the app off screen"

"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/test.jpg" "$SCREEN_OFF_PHOTO_NAME" || exit 1

wait_for_asset_count 3 || exit 1

# Back to the app. The gallery has to hold all three, which is what proves the photos taken while it was away are in the database it
# opens rather than merely on disk somewhere.
"${PLATFORM}_bring_app_to_front" || exit 1
wait_for_ready "$APP_PORT"

# The gallery has to catch up on its own, with nobody opening the database again.
#
# It was open throughout, and the two photos taken in while the app was away were announced to a web view that was not running to hear
# it. Nothing replays those, so a gallery holding all three can only have reloaded: coming back to the screen is what does it. Without
# that the gallery goes on showing the one photo it held when the user left, however many have been backed up since, and the only way
# to see the truth is to know to open the database again.
#
# What is asserted is the count the gallery ends up showing, not the reload that gets it there, and the difference matters. Waiting for
# an import pass to report all three as "already there" first walks the log cursor past everything below, because that line arrives
# after the reload. Waiting for the reload itself to report three assets is wrong in a subtler way: the counting above asks the
# filesystem, and a photo's file is written before its record is committed, so the app can come back while the third photo is a file
# and not yet a record. The reload then correctly loads two, the third is committed a moment later and arrives live, and the gallery
# reaches three having never reloaded three.
#
# Three in the gallery is the whole of what this scenario is about, and it cannot happen without the reload: the photo taken in while
# the app was off screen was announced to a web view that was not running to hear it, nothing replays that, and a later pass reports it
# as already there rather than announcing it again. So a gallery that reaches three has been reloaded, which is the thing being proven.
#
# It is the count the open gallery shows that is read, rather than a log line written when a load finishes: a desktop never takes the
# window off screen, so its gallery is brought up to date by the photos being announced as they arrive and never reloads. Either way, the
# number is what the user sees.
wait_for_value_matching "$APP_PORT" "database-photo-count" "^3 photos$" 240 || exit 1

# Switching automatic import off stops the import, and leaves the service up for syncing.
#
# The service hosts both loops and the two features are switched on separately, so it stops when NEITHER is on and not before. Syncing
# is on by default and this scenario has opened a database, which is what gives the sync loop something to push, so this first toggle
# must not take the service down: doing so would stop background syncing for somebody who only switched automatic import off.
#
# The settings card is still on screen from when the toggle was switched on: nothing in this scenario closed the configuration dialog,
# and it is drawn over whatever page the app is on rather than belonging to one. Asking for it again would do nothing at all, because
# the dialog is already open, and the card would not be built again, so the line saying it had read its settings would never come and
# this would wait for it until it gave up.
send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "$("${PLATFORM}_auto_import_stopped_log")" || exit 1

sleep 3
if ! "${PLATFORM}_background_work_running"; then
    log_error "The foreground service stopped when automatic import was switched off, taking background syncing down with it. They are switched on separately and only both being off may stop it."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi
log_info "The foreground service is still running for syncing, with automatic import switched off"

# Now with syncing switched off as well, nothing is left to run: no service, and with it no notification.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "$("${PLATFORM}_sync_stopped_log")" || exit 1

STOPPED=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! "${PLATFORM}_background_work_running"; then
        STOPPED=1
        break
    fi
    sleep 1
done

if [ "$STOPPED" -ne 1 ]; then
    log_error "The foreground service is still running with both automatic import and syncing switched off. Its notification stays up and the phone keeps working for nothing."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi
log_info "The foreground service stopped once neither automatic import nor syncing was on"

# The fixture photo test.jpg carries GPS tags whose fractions are all 0/0, which the importer reports as out of range at error level
# and then ignores, so that report is ignored along with the thumbnail fetches; any other error fails the scenario.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 49 passed: background-import"
