#!/bin/bash

# Syncing carrying on while the app is not on screen, and while the screen is off.
#
# This is the other half of what test 49 proves. A photo taken while the app is backgrounded reaches
# the device's own database there, and this test is about what happens next: it has to reach the
# remote copy as well, without anybody opening the app. For a photo backup app that is the half that
# matters, because the photo is on the phone either way.
#
# Everything is measured by reading the S3 origin from the host, never by anything the app says. Log
# lines reach app.log over a WebSocket from the WebView to the host bridge, and a backgrounded WebView
# may have that socket suspended, which is exactly the moment this test cares about. The origin is
# outside the phone altogether, so it keeps answering.
#
# The negative case matters as much as the positive one: with `Enable syncing` switched off, the photo
# still has to reach the local database and nothing at all may reach the origin, with the app and its
# service still running throughout. A test that only checked the positive case would pass on an app
# that ignored the setting, and would pass on an app that had crashed.
#
# It runs against a real phone as well as an emulator, and on a phone it never wipes anything. An
# emulator gets `pm clear` like every other mobile test; a phone gets its settings files and its
# keychain saved and handed back at the end, and the database this test syncs is named for the test
# rather than being the phone's own default. That matters because the phone this was written against
# holds a real imported photo library, and `pm clear` would destroy it.
#
# The `Only sync over Wi-Fi` restriction is NOT covered here. Driving it needs the device's connection
# type changed to cellular, and reconfiguring a pool emulator's radios is forbidden by
# apps/android-frontend/CLAUDE.md: it is shared with every other run on this machine. The rule itself
# is covered by unit tests, in packages/api (computeSyncAllowed) and packages/mobile-worker
# (plan-sync.worker), including the cellular case this cannot reach.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 50 "background-sync"

# Android only. iOS cannot do this: a BGProcessingTask is scheduled by the system and the only way to
# force one is an lldb command against a running app, which this harness has no way to issue on
# Xcode 14.2. See IOS-NOT-COVERED.md beside this file.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: the background sync is covered on Android only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="background-sync-smoke-test-s3"

# The database this test seeds and syncs.
#
# Named for the test rather than "photosphere-default", so a run against a real phone never touches
# the database that phone actually backs up to. Which database the background sync pushes is whatever
# auto-import.toml names, and this test names this one for as long as it runs.
DB_NAME="background-sync-test-db"

# True when this run is against a real phone rather than an emulator. Two things depend on it: the
# app's data is never wiped on a phone, and the last photo is a small one, for the reason below.
IS_REAL_DEVICE=0
case "${ANDROID_SERIAL:-}" in
    ""|emulator-*)
        ;;
    *)
        IS_REAL_DEVICE=1
        ;;
esac

# The photos put into the device library, named so a parallel run cannot collide with them. All three
# are declared here so the exit trap can clean them up whether or not the test got that far.
ANCHOR_PHOTO_NAME="psphere-background-sync-anchor-$$.jpeg"
BACKGROUNDED_PHOTO_NAME="psphere-background-sync-backgrounded-$$.png"

# The last photo is two megabytes on an emulator and a small one on a phone, and the difference is
# the route to this host rather than anything about syncing.
#
# An emulator is on the LAN bridge and reaches the S3 server over a real network. A phone reaches it
# through the port reverses adb sets up over USB, because the app permits cleartext to localhost only,
# and a two megabyte upload through that tunnel times out every time: measured with the screen on and
# with it off, and with the same photo in the backgrounded step, so it is the upload and not the state
# of the phone. Small photos go through it without trouble. The large upload is worth keeping where it
# can run, so the emulator keeps it and the phone proves the same loop with a photo its route can
# carry.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    SCREEN_OFF_PHOTO_NAME="psphere-background-sync-screen-off-$$.png"
    SCREEN_OFF_PHOTO_SOURCE="$REPO_DIR/test/test.png"
else
    SCREEN_OFF_PHOTO_NAME="psphere-background-sync-screen-off-$$.jpg"
    SCREEN_OFF_PHOTO_SOURCE="$REPO_DIR/test/test.jpg"
fi

# The directory this run's photos go into, which is its own album as far as MediaStore is concerned.
#
# Its own directory, and its own album, because automatic import is pointed at that album and nothing
# else. Watching the whole library is what every other mobile test does and is right on an emulator
# with nothing on it; on a phone it would import somebody's entire photo collection into this test's
# database, and every import pass would take long enough that the sync loop never got a turn.
TEST_ALBUM_DIR="/sdcard/DCIM/psphere-background-sync-$$"

# The database automatic import writes into, and the directory inside it holding one file per
# original. Counting those says what the phone imported, which is the half this test takes for
# granted; what reaches the bucket is what it is about.
DEFAULT_DATABASE_DIR="files/$DB_NAME"
ASSET_DIR="$DEFAULT_DATABASE_DIR/asset"

# How long to wait for a photo to reach the origin with the app off screen. The gap between sync
# passes is seeded down to a few seconds below, but a pass has an import pass to wait behind, a
# database to open and a bucket to talk to.
SYNC_TIMEOUT_SECONDS=240

# How long to watch the origin to be satisfied that nothing is being pushed to it. Long enough for
# several sync passes at the seeded gap: a shorter window would pass on an app that was about to push.
NO_SYNC_WINDOW_SECONDS=60

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
# How many files the origin database in the bucket holds.
#
# Read with the CLI from the host, which is the whole point: the phone is off screen and may be
# telling nobody anything. One photo is several files (the original, the display copy and two
# thumbnails), so this is a number to compare against itself rather than a count of photos.
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
    adb logcat -d -s AutoImportService:* 2>/dev/null | tail -60 || true
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
    adb shell run-as "$APP_ID" ls -R "$DEFAULT_DATABASE_DIR" 2>/dev/null | tr -d '\r' | head -40 || true
    adb logcat -d -s AutoImportService:* 2>/dev/null | tail -60 || true
    return 1
}

#
# True when the foreground service is running.
#
auto_import_service_running() {
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"
}

# Where the device's own settings files are kept while this test has its own in place. Only used on a
# real phone; on an emulator the app's data is wiped instead and there is nothing to keep.
SAVED_SETTINGS_DIR="$TMP_DIR/device-settings"

# True when this target's app data may be wiped, which is every emulator and no phone.
CAN_WIPE_APP_DATA=0
if android_may_wipe_app_data; then
    CAN_WIPE_APP_DATA=1
fi

# Removes the photos from the device library, puts the screen back on, hands the phone its own
# settings back, and stops both the app and the S3 emulator, however the test ends. A screen left off
# poisons every test after it on that emulator, and a MinIO server left running holds a port.
on_exit() {
    local exit_code=$?
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    # The directory is passed with every one of these: without it the file is left on disk while its
    # MediaStore row goes, and the next volume scan puts the row back. Photos left that way are photos
    # the next test imports and counts.
    "${PLATFORM}_remove_media" "$ANCHOR_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$BACKGROUNDED_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$SCREEN_OFF_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
    # The directory the three photos were in. Empty by now, and removed by name rather than
    # recursively, which is the only kind of delete a test may run.
    adb shell rmdir "$TEST_ALBUM_DIR" >/dev/null 2>&1 || true
    stop_app "$APP_PORT" "$TMP_DIR"

    # The phone gets its settings back before anything else, and whether the test passed or not: they
    # say which database its photos are backed up to, and leaving this test's in place would have it
    # backing up into a test database.
    if [ "$CAN_WIPE_APP_DATA" -ne 1 ]; then
        android_restore_sandbox_file "$AUTO_IMPORT_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$AUTO_IMPORT_CONFIG_FILE"
        android_restore_sandbox_file "$SYNC_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$SYNC_CONFIG_FILE"
        android_restore_sandbox_file "$DATABASES_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$DATABASES_CONFIG_FILE"

        # The keychain goes back as it was, which takes the S3 credentials this test added with it.
        # The app offers no way to delete a secret, so this is the only way not to leave one on
        # somebody's phone.
        android_restore_app_data_file "$SECURE_STORE_FILE" "$SAVED_SETTINGS_DIR/secure-store.xml"

        log_info "Left behind on this device: the test database at files/$DB_NAME, which nothing reads once the settings above are back. It cannot be removed from here, because a recursive delete is not something a test may run."
    fi

    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap on_exit EXIT

mkdir -p "$TMP_DIR"

# A locked phone cannot run this test, and it is worth saying so here rather than letting it fail
# four minutes later on an empty database.
#
# From Android 12 an app that is not in the foreground may not start a foreground service, and an app
# launched behind a lock screen is not in the foreground however visible it looks: the platform
# refuses the service, so no import and no sync ever run. Nothing a test can do gets past a secure
# lock screen, and nothing should. Emulators have no lock screen and never take this path.
device_is_locked() {
    adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -q "mDreamingLockscreen=true"
}

if device_is_locked; then
    # An emulator, and a phone with no secure lock, are dismissed by waking the screen and swiping
    # up, which is what a person does without thinking about it. Tried before giving up, because a CI
    # emulator that boots to a swipe lock is a device this test can perfectly well run on.
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb shell input keyevent 82 >/dev/null 2>&1 || true
    adb shell input swipe 540 1800 540 600 >/dev/null 2>&1 || true
    sleep 1
fi

if device_is_locked; then
    log_error "${ANDROID_SERIAL:-The device} is showing a lock screen that cannot be dismissed from here, so Android will refuse the foreground service this test is about and nothing will be imported or synced."
    log_error "Unlock the device and run this again."
    exit 1
fi

# --- 1. The origin database, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/background-sync-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used
# directly on the command line. The host reaches the emulator on loopback; only the device needs the
# host address that start_s3_emulator worked out.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the origin database in the bucket with the CLI"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_ORIGIN_PATH" --yes || exit 1

# --- 2. The phone's database, which is a partial replica of that origin. ---

# A replica rather than a fresh database, because sync moves content between two databases that are
# copies of each other. This is what `psi consolidate` does for a user on the desktop, and what the
# app has no way to do on mobile yet, so the test does it from the host.
LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
run_cli "$TMP_DIR" replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes || exit 1

# Point the replica at the origin. This is the file plan-sync reads to find out there is somewhere to
# sync to, and the sync handler reads to find out where.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

ORIGIN_FILES_AT_START="$(origin_file_count)"
log_info "The origin holds $ORIGIN_FILES_AT_START file(s) before the phone touches it"

# --- 3. Put it all on the phone, with syncing switched OFF to start with. ---

# An emulator gets the clean start every other mobile test gets. A real phone does not: `pm clear`
# would destroy the photo library it has imported, which is hours of somebody's work, and this test
# does not need it. What it needs is for its own settings to be in place while it runs and the
# phone's own to be back afterwards, so on a phone they are saved and put back by the exit trap.
if [ "$CAN_WIPE_APP_DATA" -eq 1 ]; then
    "${PLATFORM}_reset_app_state" || exit 1
else
    log_info "Running against a real device: borrowing its settings rather than wiping its data"
    mkdir -p "$SAVED_SETTINGS_DIR"
    android_save_sandbox_file "$AUTO_IMPORT_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$AUTO_IMPORT_CONFIG_FILE"
    android_save_sandbox_file "$SYNC_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$SYNC_CONFIG_FILE"
    android_save_sandbox_file "$DATABASES_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$DATABASES_CONFIG_FILE"
    android_save_app_data_file "$SECURE_STORE_FILE" "$SAVED_SETTINGS_DIR/secure-store.xml"

    # Stopped so the settings written below are read at the next launch rather than fought over by a
    # copy of the app that is already running with the phone's own.
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
fi

# Sweep up anything a previous run of this test left behind, in this run's album directory and in
# every earlier run's. A run killed outright never reaches its exit trap, and the photos it leaves are
# imported and counted by whatever runs next: tests 47 and 49 both count what a pass takes in, and
# both failed once on three abandoned runs' worth of this test's photos.
#
# The files go first and the MediaStore rows second, because a row removed while its file remains is
# put back by the next scan of the volume. The glob is a plain file delete, not a recursive one, and
# the now-empty directories go with rmdir.
adb shell "rm -f /sdcard/DCIM/psphere-background-sync-*/*" >/dev/null 2>&1 || true
adb shell "rmdir /sdcard/DCIM/psphere-background-sync-*" >/dev/null 2>&1 || true
"${PLATFORM}_remove_media_matching" "psphere-background-sync-" || true

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1

# Both databases are registered: the on-device replica and its origin in the bucket. Credentials are
# resolved by exact path, and the sync handler opens the origin by the path recorded in the replica's
# own config, so without an entry for that path the origin is opened with no credentials at all and
# every read of it fails with "Region is missing".
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"},{\"name\":\"$DB_NAME-origin\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

# One photo in the test's own album before anything else, so the album exists and MediaStore can be
# asked for its id. Automatic import is then pointed at that album alone, and this photo is the first
# thing it takes in.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ANCHOR_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

TEST_ALBUM_ID="$(android_media_album_id "$ANCHOR_PHOTO_NAME")"
if [ -z "$TEST_ALBUM_ID" ]; then
    log_error "MediaStore did not file $ANCHOR_PHOTO_NAME under an album, so automatic import cannot be pointed at one."
    exit 1
fi
log_info "The test's photos are in album $TEST_ALBUM_ID ($TEST_ALBUM_DIR)"

# The photo permission, from outside the app: the system dialog cannot be tapped by a test, and the
# app's own request resolves straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

# And the notification permission, which the foreground service needs to post its notification.
"${PLATFORM}_grant_notification_permission" || exit 1

# The app starts with both loops off, and is given its credentials before either of them runs.
#
# The other way round does not work on a phone. Automatic import walks the whole photo library's
# listing on every pass even when it imports nothing from it, which on a phone holding a real
# collection takes several seconds of a pass every few seconds, and the app was busy enough that the
# first tap of the settings card never got an answer. It is also the wrong order on its own terms: a
# sync pass that runs before the credentials exist fails, and a test should not need failures it does
# not care about to get to the ones it does.
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials for the bucket, added the way a user adds them. Without these the sync reaches the
# origin with no credentials and fails every pass.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# Automatic import on, writing into the replica, watching this test's album and nothing else.
# Switching the toggle on through the settings card would make the app create a database of its own
# and watch the whole library, which would have no origin to sync to and, on a phone, would import
# somebody's entire photo collection; test 47 and test 49 cover that path on an emulator. The gap
# between passes is seeded short so the test is not waiting out the thirty second default several
# times over.
"${PLATFORM}_seed_auto_import_config" "true" "$DB_NAME" "5000" "$TEST_ALBUM_ID" || exit 1

# Syncing switched OFF, which is the first thing this test asserts. Seeded rather than driven through
# the settings card because the card writes the same file, and this is the state the app has to start
# in for the negative case to mean anything.
"${PLATFORM}_seed_sync_config" "false" "false" "5000" || exit 1

# Restarted so it reads the settings just written. Nothing outside the app tells it a settings file
# has changed, and the loops are started by the app when it finds automatic import on at launch.
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

# The app finds automatic import already switched on and hands the loop to the native side. That
# service hosts the sync loop as well, which is what everything below depends on.
#
# Waited for on the device rather than in app.log, because the app says "Starting automatic import."
# as it launches, which is before this test has done anything: the settings were already on. A
# wait_for_log here would start looking after that line had gone past and time out on a working app.
SERVICE_STARTED=0
for _ in $(seq 1 60); do
    if auto_import_service_running; then
        SERVICE_STARTED=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_STARTED" -ne 1 ]; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported or synced once the app leaves the screen."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service is running"

# --- 4. With syncing off: the photo is imported and nothing reaches the origin. ---

# The anchor photo first, on screen, so the counting below starts from a settled number rather than
# racing the first pass.
wait_for_asset_count 1 || exit 1

log_info "Sending the app to the background"
adb shell input keyevent KEYCODE_HOME || exit 1
sleep 2

"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-2.png" "$BACKGROUNDED_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

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
if ! auto_import_service_running; then
    log_error "The foreground service is gone. Nothing was pushed to the origin because the service stopped, not because syncing is switched off."
    exit 1
fi
if ! adb shell pidof "$APP_ID" >/dev/null 2>&1; then
    log_error "The app is not running. Nothing was pushed to the origin because the app died, not because syncing is switched off."
    exit 1
fi
log_success "The app and its service are still running with syncing switched off"

# --- 5. Switch syncing on, and the same photo arrives. ---

# Written to the settings file rather than tapped in the app, because the app is off screen and this
# is what the toggle writes. The loop re-reads the file every pass, so nothing has to be restarted.
"${PLATFORM}_seed_sync_config" "true" "false" "5000" || exit 1

wait_for_origin_growth "$ORIGIN_FILES_AT_START" "The photo imported while the app was backgrounded reached the origin" || exit 1
ORIGIN_FILES_AFTER_FIRST="$(origin_file_count)"

# --- 6. Syncing carries on with automatic import switched off. ---
#
# The two features are switched on separately and share one service, and tying them together would
# mean somebody who imports by hand and syncs gets no background syncing at all. Automatic import goes
# off here and the sync loop has to keep running: the service stays up, and it goes on asking whether
# a sync should run.
#
# Before the screen goes off, deliberately. A phone with a secure lock screen locks itself when the
# screen goes off, and an app relaunched behind a lock screen is refused its foreground service by the
# platform, so everything after that point is untestable there. Nothing about this case needs the
# screen off.
"${PLATFORM}_seed_auto_import_config" "false" "$DB_NAME" "5000" "$TEST_ALBUM_ID" || exit 1

# Restarted because a settings file changed from outside is only read at launch: the app notices its
# own writes, not the harness's.
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

SERVICE_UP=0
for _ in $(seq 1 30); do
    if auto_import_service_running; then
        SERVICE_UP=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_UP" -ne 1 ]; then
    log_error "The foreground service is not running with automatic import off and syncing on. Background syncing needs it, and the two features are switched on separately."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi

# The service being up is not the same as the sync loop asking. Logcat is where the loop says what it
# is doing, and it keeps working with the app off screen, which is why it is read rather than app.log.
adb logcat -c >/dev/null 2>&1 || true
adb shell input keyevent KEYCODE_HOME || exit 1

SYNC_PASS_SEEN=0
for _ in $(seq 1 30); do
    if adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep -qE "Syncing \"|Not syncing"; then
        SYNC_PASS_SEEN=1
        break
    fi
    sleep 2
done

if [ "$SYNC_PASS_SEEN" -ne 1 ]; then
    log_error "The sync loop stopped when automatic import was switched off. It has to carry on: the two are switched on separately."
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tail -30 || true
    exit 1
fi
log_success "Syncing carries on in the background with automatic import switched off"

# Automatic import goes back on for the screen-off case below, which is about the import and the sync
# together.
#
# Waited for on the app's own word rather than on a sleep, and with the app left on screen: the photo
# permission is asked for as the loop starts, and that is a round trip to the platform which a
# backgrounded app has no reason to answer promptly. Sending it away before it has finished starting
# is how this step first failed, silently, with nothing importing for the rest of the test. The screen
# going off below is what backgrounds it, which is the state the case is about anyway.
"${PLATFORM}_seed_auto_import_config" "true" "$DB_NAME" "5000" "$TEST_ALBUM_ID" || exit 1
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"
wait_for_log "$TMP_DIR" "Starting automatic import." 120 || exit 1

# --- 7. And again with the screen off, which is the harder case. ---

# Emulators only, and not because the case is uninteresting: it is the one the wake lock exists for.
#
# Turning the screen off on a phone with a secure lock screen locks it, and nothing a test may do can
# unlock it again: no test should know somebody's PIN. The phone is then left locked for whoever picks
# it up next, and every later run of this test refuses to start on it. An emulator has no lock screen,
# so it runs there every time, including in the release workflow.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    log_info "SKIP (the screen-off case): turning the screen off would leave this phone locked, and a test cannot unlock it. It runs on every emulator."
else
    # A foreground service keeps the process alive but does not by itself keep the CPU awake; the wake
    # lock the service takes for the length of a pass is what makes this work.
    log_info "Turning the screen off"
    adb shell input keyevent KEYCODE_POWER || exit 1
    sleep 2

    "${PLATFORM}_seed_media" "$SCREEN_OFF_PHOTO_SOURCE" "$SCREEN_OFF_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

    wait_for_asset_count 3 || exit 1
    wait_for_origin_growth "$ORIGIN_FILES_AFTER_FIRST" "The photo taken with the screen off reached the origin" || exit 1

    log_info "Turning the screen back on"
    adb shell input keyevent KEYCODE_WAKEUP || exit 1
    adb shell input keyevent KEYCODE_MENU >/dev/null 2>&1 || true
    sleep 2
fi

# The app was never opened between the photo landing and it reaching the bucket, which is the whole
# claim of this test. Bringing it back now is only so the log can be checked for errors.
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 50 passed: background-sync"
