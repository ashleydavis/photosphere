#!/bin/bash

# Syncing carrying on while the app is not on screen, and while the screen is off.
#
# This is the other half of what the background-import scenario proves. A photo taken while the app is backgrounded reaches the
# device's own database there, and this scenario is about what happens next: it has to reach the remote copy as well, without anybody
# opening the app. For a photo backup app that is the half that matters, because the photo is on the phone either way.
#
# Everything is measured by reading the S3 origin from the host, never by anything the app says. Log lines reach app.log from the web
# view, and a backgrounded web view may be suspended, which is exactly the moment this scenario cares about. The origin is outside the
# phone altogether, so it keeps answering.
#
# The negative case matters as much as the positive one: with `Enable syncing` switched off, the photo still has to reach the local
# database and nothing at all may reach the origin, with the app and its service still running throughout. A scenario that only checked
# the positive case would pass on an app that ignored the setting, and would pass on an app that had crashed.
#
# It runs against a real phone as well as an emulator, and on a phone it never wipes anything. An emulator gets `pm clear` like every
# other mobile scenario; a phone gets its settings files and its keychain saved and handed back at the end, and the database this
# scenario syncs is named for it rather than being the phone's own default. That matters because a phone this runs on may hold a real
# imported photo library, and `pm clear` would destroy it.
#
# The `Only sync over Wi-Fi` restriction is NOT covered here. Driving it needs the device's connection type changed to cellular, and
# reconfiguring a pool emulator's radios is forbidden: it is shared with every other run on this machine. The rule itself is covered by
# the unit tests of the sync plan, including the cellular case this cannot reach.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 50 "background-sync"

# Not on iOS. iOS cannot do this: a BGProcessingTask is scheduled by the system and the only way to force one is an lldb command
# against a running app, which this harness has no way to issue on Xcode 14.2.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: the background sync is covered on Android and the desktop only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

"${PLATFORM}_claim_device" || exit 1

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="background-sync-smoke-test-s3"

# The database this scenario seeds and syncs.
#
# Named for the scenario rather than "photosphere-default", so a run against a real phone never touches the database that phone actually
# backs up to. Which database the background sync pushes is whatever config.yaml names, and this scenario names this one for as long as
# it runs. The app resolves no relative path against its storage, so the path is the absolute one in the app's files directory.
DB_NAME="background-sync-test-db"
DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"

# True when this run is against a real phone rather than an emulator. Two things depend on it: the app's data is never wiped on a phone,
# and the last photo is a small one, for the reason below.
IS_REAL_DEVICE=0
if "${PLATFORM}_is_real_device"; then
    IS_REAL_DEVICE=1
fi

# The photos put into the device library, named so a parallel run cannot collide with them. All three are declared here so the exit
# trap can clean them up whether or not the scenario got that far.
ANCHOR_PHOTO_NAME="psphere-background-sync-anchor-$$.jpeg"
BACKGROUNDED_PHOTO_NAME="psphere-background-sync-backgrounded-$$.png"

# The last photo is two megabytes on an emulator and a small one on a phone, and the difference is the route to this host rather than
# anything about syncing.
#
# An emulator is on the LAN bridge and reaches the S3 server over a real network. A phone reaches it through the port reverses adb sets
# up over USB, because the app permits cleartext to localhost only, and a two megabyte upload through that tunnel times out every time:
# measured with the screen on and with it off, and with the same photo in the backgrounded step, so it is the upload and not the state
# of the phone. Small photos go through it without trouble. The large upload is worth keeping where it can run, so the emulator keeps it
# and the phone proves the same loop with a photo its route can carry.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    SCREEN_OFF_PHOTO_NAME="psphere-background-sync-screen-off-$$.png"
    SCREEN_OFF_PHOTO_SOURCE="$REPO_DIR/test/test.png"
else
    SCREEN_OFF_PHOTO_NAME="psphere-background-sync-screen-off-$$.jpg"
    SCREEN_OFF_PHOTO_SOURCE="$REPO_DIR/test/test.jpg"
fi

# The library this run's photos go into, which is a folder of its own and, on a phone, an album of its own.
#
# Its own, because automatic import is pointed at that library and nothing else. Watching the whole library is right on an emulator
# with nothing on it; on a phone it would import somebody's entire photo collection into this scenario's database, and every import
# pass would take long enough that the sync loop never got a turn.
LIBRARY_PREFIX="psphere-background-sync"
LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"

# Where the saved settings of a real phone are kept while this scenario has its own in place. Not used on an emulator or a desktop,
# where the app's data is wiped instead and there is nothing to keep.
SAVED_SETTINGS_DIR="$TMP_DIR/device-settings"

# How long to wait for a photo to reach the origin with the app off screen. The gap between sync passes is seeded down to a few seconds
# below, but a pass has an import pass to wait behind, a database to open and a bucket to talk to.
SYNC_TIMEOUT_SECONDS=240

# How long to watch the origin to be satisfied that nothing is being pushed to it. Long enough for several sync passes at the seeded
# gap: a shorter window would pass on an app that was about to push.
NO_SYNC_WINDOW_SECONDS=60

#
# How many originals the app's database holds right now, or 0 when there is no database yet.
#
# Read from outside the app, which is the only way to see its storage on a phone.
#
asset_count() {
    "${PLATFORM}_asset_count" "$DB_NAME"
}

#
# How many files the origin database in the bucket holds.
#
# Read with the CLI from the host, which is the whole point: the phone is off screen and may be telling nobody anything. One photo is
# several files (the original, the display copy and two thumbnails), so this is a number to compare against itself rather than a count
# of photos.
#
origin_file_count() {
    run_cli "$TMP_DIR" summary --db "$S3_ORIGIN_PATH" --yes 2>/dev/null \
        | tr -d '\r' \
        | grep "Total files:" \
        | grep -o '[0-9][0-9]*' \
        | head -1
}

#
# Waits until the origin holds more files than the given count.
#
wait_for_origin_growth() {
    local baseline="$1"
    local what="$2"
    local elapsed=0

    # A phone's background loop pushes what it imported by itself. A desktop syncs after an edit and on a timer of several minutes, and
    # an automatic import is neither, so it is told the database was edited, as it is when the user changes something.
    "${PLATFORM}_request_sync" "$APP_PORT" || return 1
    while [ "$elapsed" -lt "$SYNC_TIMEOUT_SECONDS" ]; do
        local actual
        actual="$(origin_file_count)"
        if [ "${actual:-0}" -gt "$baseline" ]; then
            log_success "$what: the origin grew from $baseline to $actual file(s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "$what: the origin still holds $(origin_file_count) file(s), unchanged from $baseline"
    "${PLATFORM}_dump_background_diagnostics"
    return 1
}

#
# Waits until the app's database holds at least the given number of originals.
#
wait_for_asset_count() {
    local expected="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$SYNC_TIMEOUT_SECONDS" ]; do
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

#
# Stops the app and starts it again on the data it left, so it reads the settings written from outside since it started: nothing
# outside the app tells it a settings file has changed, and the loops start when the app finds automatic import on at launch.
#
restart_app() {
    stop_app "$APP_PORT" "$TMP_DIR"
    reset_log_cursor "$TMP_DIR"
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"
}

# True when this target's app data may be wiped, which is every emulator and desktop and no phone.
CAN_WIPE_APP_DATA=0
if "${PLATFORM}_may_wipe_app_data"; then
    CAN_WIPE_APP_DATA=1
fi

# Removes the photos from the library, puts the screen back on, hands the phone its own settings back, and stops both the app and the S3
# emulator, however the scenario ends. A screen left off poisons every scenario after it on that emulator, and a MinIO server left
# running holds a port.
on_exit() {
    local exit_code=$?
    "${PLATFORM}_screen_on" >/dev/null 2>&1 || true
    # The photos are named with the library: without it the file is left on disk while the phone's record of it goes, and the next
    # volume scan puts the record back. Photos left that way are photos the next scenario imports and counts.
    "${PLATFORM}_library_remove" "$LIBRARY" "$ANCHOR_PHOTO_NAME" "$BACKGROUNDED_PHOTO_NAME" "$SCREEN_OFF_PHOTO_NAME" 2>/dev/null || true
    cleanup_apps "$TMP_DIR"

    # The phone gets its settings back before anything else, and whether the scenario passed or not: they say which database its
    # photos are backed up to, and leaving this scenario's in place would have it backing up into a test database.
    if [ "$CAN_WIPE_APP_DATA" -ne 1 ]; then
        "${PLATFORM}_return_app_settings" "$SAVED_SETTINGS_DIR"

        log_info "Left behind on this device: the test database at files/$DB_NAME, which nothing reads once the settings above are back. It cannot be removed from here, because a recursive delete is not something a test may run."
    fi

    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap on_exit EXIT

mkdir -p "$TMP_DIR"

# A locked phone cannot run this scenario, and it is worth saying so here rather than letting it fail four minutes later on an empty
# database.
#
# From Android 12 an app that is not in the foreground may not start a foreground service, and an app launched behind a lock screen is
# not in the foreground however visible it looks: the platform refuses the service, so no import and no sync ever run. Nothing a script
# can do gets past a secure lock screen, and nothing should. Emulators and desktops have no lock screen and never take this path.
"${PLATFORM}_require_unlocked" || exit 1

# --- 1. The origin database, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/background-sync-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used directly on the command line.
# The host reaches the emulator on loopback; only the device needs the host address that start_s3_emulator worked out.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the origin database in the bucket with the CLI"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
# Not the photo this scenario later puts into the library as its anchor: an import recognises a photo the database already holds and
# does not take it in again, which is correct and is what the counts below would then wait on forever.
run_cli "$TMP_DIR" add "$REPO_DIR/test/duplicate-images/a.png" --db "$S3_ORIGIN_PATH" --yes || exit 1

# --- 2. The phone's database, which is a partial replica of that origin. ---

# A replica rather than a fresh database, because sync moves content between two databases that are copies of each other. This is what
# `psi consolidate` does for a user on the desktop, and what the app has no way to do on a phone yet, so the scenario does it from the
# host.
LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
run_cli "$TMP_DIR" replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes || exit 1

# Point the replica at the origin. This is the file the sync plan reads to find out there is somewhere to sync to, and the sync handler
# reads to find out where.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

ORIGIN_FILES_AT_START="$(origin_file_count)"
log_info "The origin holds $ORIGIN_FILES_AT_START file(s) before the phone touches it"

# --- 3. Put it all on the phone, with syncing switched OFF to start with. ---

# An emulator gets the clean start every other mobile scenario gets. A real phone does not: `pm clear` would destroy the photo library
# it has imported, which is hours of somebody's work, and this scenario does not need it. What it needs is for its own settings to be in
# place while it runs and the phone's own to be back afterwards, so on a phone they are saved and put back by the exit trap.
if [ "$CAN_WIPE_APP_DATA" -eq 1 ]; then
    "${PLATFORM}_reset_app_state" || exit 1
else
    log_info "Running against a real device: borrowing its settings rather than wiping its data"
    "${PLATFORM}_borrow_app_settings" "$SAVED_SETTINGS_DIR" || exit 1
fi

# Sweep up anything a previous run of this scenario left behind, in this run's library and in every earlier run's. A run killed outright
# never reaches its exit trap, and the photos it leaves are imported and counted by whatever runs next: the auto-import scenarios count
# what a pass takes in.
"${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1

# Both databases are registered: the on-device replica and its origin in the bucket. Credentials are resolved by exact path, and the
# sync handler opens the origin by the path recorded in the replica's own config, so without an entry for that path the origin is opened
# with no credentials at all and every read of it fails with "Region is missing".
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"},{\"name\":\"$DB_NAME-origin\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

# A desktop syncs the database that is open, so the replica is the one the app opens when it starts. A phone's background loops work on
# the database the settings name and need nothing open.
"${PLATFORM}_open_database_on_launch" "$DB_PATH" || exit 1

# One photo in the scenario's own library before anything else, so the library exists and the device can be asked about it. Automatic
# import is then pointed at that library alone, and this photo is the first thing it takes in.
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ANCHOR_PHOTO_NAME" || exit 1

# The photo permission, from outside the app: the system dialog cannot be tapped by a script, and the app's own request resolves
# straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission, which the foreground service needs to post its notification.
"${PLATFORM}_grant_notification_permission" || exit 1

# The app starts with both loops off, and is given its credentials before either of them runs.
#
# The other way round does not work on a phone. Automatic import walks the whole photo library's listing on every pass even when it
# imports nothing from it, which on a phone holding a real collection takes several seconds of a pass every few seconds, and the app
# was busy enough that the first tap of the settings card never got an answer. It is also the wrong order on its own terms: a sync pass
# that runs before the credentials exist fails, and a scenario should not need failures it does not care about to get to the ones it
# does.
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials for the bucket, added the way a user adds them. Without these the sync reaches the origin with no credentials and
# fails every pass.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# Automatic import on, writing into the replica, watching this scenario's album and nothing else. Switching the toggle on through the
# settings card would make the app create a database of its own, which would have no origin to sync to, so this scenario seeds the
# setting instead; the auto-import and background-import scenarios are the ones that go through the card. Every one of the three
# watches an album of its own, because watching the whole library means importing somebody's photo collection on a real phone. The gap
# between passes is seeded short so the scenario is not waiting out the thirty second default several times over.
"${PLATFORM}_seed_library_auto_import_config" "true" "$DB_PATH" "5000" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1

# Syncing switched OFF, which is the first thing this scenario asserts. Seeded rather than driven through the settings card because the
# card writes the same file, and this is the state the app has to start in for the negative case to mean anything.
"${PLATFORM}_seed_sync_config" "false" "false" "1000" "$DB_PATH" || exit 1

restart_app

# The app finds automatic import already switched on and hands the loop to the core. That service hosts the sync loop as well, which is
# what everything below depends on.
#
# Waited for on the device rather than in app.log, because the app says "Starting automatic import." as it launches, which is before
# this scenario has done anything: the settings were already on.
SERVICE_STARTED=0
for _ in $(seq 1 60); do
    if "${PLATFORM}_background_work_running"; then
        SERVICE_STARTED=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_STARTED" -ne 1 ]; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported or synced once the app leaves the screen."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi
log_info "The foreground service is running"

# --- 4. With syncing off: the photo is imported and nothing reaches the origin. ---

# The anchor photo first, on screen, so the counting below starts from a settled number rather than racing the first pass.
wait_for_asset_count 1 || exit 1

log_info "Sending the app to the background"
"${PLATFORM}_send_app_to_background" || exit 1
sleep 2

"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-2.png" "$BACKGROUNDED_PHOTO_NAME" || exit 1

# The import half still has to work. Measured on the device's own disk, because the app is off screen.
wait_for_asset_count 2 || exit 1
log_success "A photo taken while the app was backgrounded was imported"

log_info "Watching the origin for ${NO_SYNC_WINDOW_SECONDS}s to confirm nothing is pushed while syncing is off"
ELAPSED=0
while [ "$ELAPSED" -lt "$NO_SYNC_WINDOW_SECONDS" ]; do
    CURRENT="$(origin_file_count)"
    if [ "${CURRENT:-0}" -gt "$ORIGIN_FILES_AT_START" ]; then
        log_error "The origin grew from $ORIGIN_FILES_AT_START to $CURRENT file(s) while \"Enable syncing\" was switched off."
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
log_success "Nothing reached the origin while syncing was switched off"

# A refusal to sync has to be distinguishable from a crash. An app that died would also push nothing.
if ! "${PLATFORM}_background_work_running"; then
    log_error "The foreground service is gone. Nothing was pushed to the origin because the service stopped, not because syncing is switched off."
    exit 1
fi
if ! "${PLATFORM}_app_process_alive"; then
    log_error "The app is not running. Nothing was pushed to the origin because the app died, not because syncing is switched off."
    exit 1
fi
log_success "The app and its service are still running with syncing switched off"

# --- 5. Switch syncing on, and the same photo arrives. ---

# Written to the settings file rather than tapped in the app, because the app is off screen and this is what the toggle writes. The loop
# re-reads the file every pass, so nothing has to be restarted.
"${PLATFORM}_seed_sync_config" "true" "false" "1000" "$DB_PATH" || exit 1

# A desktop reads its settings when it starts, so it is started again on the same data. A phone's loop has already seen the change.
"${PLATFORM}_apply_settings_change" || exit 1

wait_for_origin_growth "$ORIGIN_FILES_AT_START" "The photo imported while the app was backgrounded reached the origin" || exit 1
ORIGIN_FILES_AFTER_FIRST="$(origin_file_count)"

# --- 6. Syncing carries on with automatic import switched off. ---
#
# The two features are switched on separately and share one service, and tying them together would mean somebody who imports by hand
# and syncs gets no background syncing at all. Automatic import goes off here and the sync loop has to keep running: the service stays
# up, and it goes on asking whether a sync should run.
#
# Before the screen goes off, deliberately. A phone with a secure lock screen locks itself when the screen goes off, and an app
# relaunched behind a lock screen is refused its foreground service by the platform, so everything after that point is untestable
# there. Nothing about this case needs the screen off.
"${PLATFORM}_seed_library_auto_import_config" "false" "$DB_PATH" "5000" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1

# Restarted because a settings file changed from outside is only read at launch: the app notices its own writes, not the harness's.
restart_app

SERVICE_UP=0
for _ in $(seq 1 30); do
    if "${PLATFORM}_background_work_running"; then
        SERVICE_UP=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_UP" -ne 1 ]; then
    log_error "The foreground service is not running with automatic import off and syncing on. Background syncing needs it, and the two features are switched on separately."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi

# The service being up is not the same as the sync loop asking. Logcat is where the loop says what it is doing, and it keeps working
# with the app off screen, which is why it is read rather than app.log.
"${PLATFORM}_clear_background_log"
"${PLATFORM}_send_app_to_background" || exit 1

SYNC_PASS_SEEN=0
for _ in $(seq 1 30); do
    if "${PLATFORM}_sync_pass_seen"; then
        SYNC_PASS_SEEN=1
        break
    fi
    sleep 2
done

if [ "$SYNC_PASS_SEEN" -ne 1 ]; then
    log_error "The sync loop stopped when automatic import was switched off. It has to carry on: the two are switched on separately."
    "${PLATFORM}_background_log" | tail -30
    exit 1
fi
log_success "Syncing carries on in the background with automatic import switched off"

# Automatic import goes back on for the screen-off case below, which is about the import and the sync together.
#
# Waited for on the app's own word rather than on a sleep, and with the app left on screen: the photo permission is asked for as the
# loop starts, and that is a round trip to the platform which a backgrounded app has no reason to answer promptly. Sending it away
# before it has finished starting is how this step first failed, silently, with nothing importing for the rest of the scenario. The
# screen going off below is what backgrounds it, which is the state the case is about anyway.
"${PLATFORM}_seed_library_auto_import_config" "true" "$DB_PATH" "5000" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1
restart_app
wait_for_log "$TMP_DIR" "$("${PLATFORM}_auto_import_started_log")" 120 || exit 1

# --- 7. And again with the screen off, which is the harder case. ---

# Emulators only, and not because the case is uninteresting: it is the one the wake lock exists for.
#
# Turning the screen off on a phone with a secure lock screen locks it, and nothing a script may do can unlock it again: no scenario
# should know somebody's PIN. The phone is then left locked for whoever picks it up next, and every later run of this scenario refuses
# to start on it. An emulator has no lock screen, so it runs there every time, including in the release workflow.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    log_info "SKIP (the screen-off case): turning the screen off would leave this phone locked, and a script cannot unlock it. It runs on every emulator."
else
    # A foreground service keeps the process alive but does not by itself keep the CPU awake; the wake lock the service takes for the
    # length of a pass is what makes this work.
    log_info "Turning the screen off"
    "${PLATFORM}_screen_off" || exit 1
    sleep 2

    "${PLATFORM}_library_add" "$LIBRARY" "$SCREEN_OFF_PHOTO_SOURCE" "$SCREEN_OFF_PHOTO_NAME" || exit 1

    wait_for_asset_count 3 || exit 1
    wait_for_origin_growth "$ORIGIN_FILES_AFTER_FIRST" "The photo taken with the screen off reached the origin" || exit 1

    log_info "Turning the screen back on"
    "${PLATFORM}_screen_on" || exit 1
    sleep 2
fi

# The app was never opened between the photo landing and it reaching the bucket, which is the whole claim of this scenario. Bringing it
# back now is only so the log can be checked for errors.
"${PLATFORM}_bring_app_to_front" || exit 1
wait_for_ready "$APP_PORT"

# The fixture photo test.jpg carries GPS tags whose fractions are all 0/0, which the importer reports as out of range at error level
# and then ignores, so that report is ignored along with the thumbnail fetches; any other error fails the scenario.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 50 passed: background-sync"
