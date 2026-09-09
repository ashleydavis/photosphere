#!/bin/bash

# Joining a phone to a database that already exists, and then importing and syncing into it.
#
# The other way round from tests 47 to 50, which all start from a phone with nothing and build its
# database up. Here the database exists first, in a bucket, with photos already in it, and the phone
# joins it by taking a copy: the credentials go in, the app replicates the remote down as a partial
# replica, and automatic import and background syncing then run against that copy. This is what
# somebody who already has a Photosphere database does when they install the app on a phone, and the
# manual guide for it is docs/testing/e2e/mobile/auto-import/auto-import-existing-remote.md.
#
# The replication is driven through the app's own Replicate dialog rather than being done from the
# host with the CLI, which is what test 50 does. That is the point of this test: the joining step is
# the one that is new, and doing it from the host would test a route no user has.
#
# Registering the replica afterwards is done through the Add Database dialog, by hand, because a
# replication does not register its destination on mobile. That is a known bug with a plan of its own
# (docs/plans/new/plan-register-replica-in-database-list.md); this test works around it deliberately
# rather than failing on it, because its subject is what happens after the two are joined.
#
# What reaches the bucket is read from the host with the CLI, never from anything the app says, for
# the reason test 50 gives: a backgrounded WebView may have its socket to the harness suspended, and
# the bucket keeps answering either way.
#
# It runs against a real phone as well as an emulator, and on a phone it never wipes anything: an
# emulator gets `pm clear`, a phone gets its settings files and its keychain saved and handed back.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 55 "existing-remote-auto-import"

# Android only, for the same reason as tests 47 to 50: the photo permission has to be granted from
# outside the app, and the foreground service that carries the background sync is Android's.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: this test needs the photo permission granted from outside the app and the Android foreground service."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="existing-remote-smoke-test-s3"

# The name and sandbox-relative path of the replica the app makes. Named for the test rather than
# "photosphere-default" so a run against a real phone never touches the database that phone backs up
# to.
DB_NAME="existing-remote-test-db"

# The name the remote is listed under on the phone. Different from the replica's, because entry names
# have to be unique and both are in the list at once.
REMOTE_DB_NAME="existing-remote-test-origin"

# True when this run is against a real phone rather than an emulator.
IS_REAL_DEVICE=0
case "${ANDROID_SERIAL:-}" in
    ""|emulator-*)
        ;;
    *)
        IS_REAL_DEVICE=1
        ;;
esac

# The photos put into the device library, named so a parallel run cannot collide with them.
ANCHOR_PHOTO_NAME="psphere-existing-remote-anchor-$$.jpeg"

# The photo taken "now", after everything is settled. Small on a phone: a phone reaches the host
# through the port reverses adb sets up over USB, and a large upload through that tunnel times out.
# Test 50 measured this.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    NEW_PHOTO_NAME="psphere-existing-remote-new-$$.png"
    NEW_PHOTO_SOURCE="$REPO_DIR/test/test.png"
else
    NEW_PHOTO_NAME="psphere-existing-remote-new-$$.jpg"
    NEW_PHOTO_SOURCE="$REPO_DIR/test/test.jpg"
fi

# The test's own album, which automatic import is pointed at and nothing else. Watching the whole
# library would import somebody's entire photo collection into this test's database on a phone.
TEST_ALBUM_DIR="/sdcard/DCIM/psphere-existing-remote-$$"

# Where the app keeps the replica's originals. Counting those says what the phone imported.
REPLICA_DIR="files/$DB_NAME"
ASSET_DIR="$REPLICA_DIR/asset"

# How long to wait for a photo to reach the origin. A pass has an import pass to wait behind, a
# database to open and a bucket to talk to.
SYNC_TIMEOUT_SECONDS=240

# How long to wait for the prefetch to bring the remote's records and thumbnails down. This is the
# slow step of the whole flow: a partial replication copies the merkle trees and nothing else, and
# opening the replica is what starts the fetch of everything they describe.
PREFETCH_TIMEOUT_SECONDS=180

#
# How many originals the app's replica holds right now, or 0 when there is no database yet.
#
asset_count() {
    adb shell run-as "$APP_ID" ls "$ASSET_DIR" 2>/dev/null | tr -d '\r' | grep -c . || true
}

#
# How many files the origin database in the bucket holds. Read with the CLI from the host.
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
# Waits until the app's replica holds at least the given number of originals.
#
wait_for_asset_count() {
    local expected="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$SYNC_TIMEOUT_SECONDS" ]; do
        local actual
        actual="$(asset_count)"
        if [ "${actual:-0}" -ge "$expected" ]; then
            log_success "The app's replica holds $actual original(s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "The app's replica never reached $expected original(s); it holds $(asset_count)"
    adb shell run-as "$APP_ID" ls -R "$REPLICA_DIR" 2>/dev/null | tr -d '\r' | head -40 || true
    return 1
}

#
# True when the foreground service is running.
#
auto_import_service_running() {
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"
}

# Where the device's own settings are kept while this test has its own in place. Real phones only.
SAVED_SETTINGS_DIR="$TMP_DIR/device-settings"

CAN_WIPE_APP_DATA=0
if android_may_wipe_app_data; then
    CAN_WIPE_APP_DATA=1
fi

on_exit() {
    local exit_code=$?
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    "${PLATFORM}_remove_media" "$ANCHOR_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$NEW_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
    adb shell rmdir "$TEST_ALBUM_DIR" >/dev/null 2>&1 || true
    stop_app "$APP_PORT" "$TMP_DIR"

    if [ "$CAN_WIPE_APP_DATA" -ne 1 ]; then
        android_restore_sandbox_file "$CONFIG_FILE" "$SAVED_SETTINGS_DIR/$CONFIG_FILE"
        android_restore_sandbox_file "$DATABASES_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$DATABASES_CONFIG_FILE"
        android_restore_app_data_file "$SECURE_STORE_FILE" "$SAVED_SETTINGS_DIR/secure-store.xml"
        log_info "Left behind on this device: the test replica at files/$DB_NAME, which nothing reads once the settings above are back."
    fi

    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap on_exit EXIT

mkdir -p "$TMP_DIR"

# A locked phone refuses the foreground service this test needs, whatever else is true.
device_is_locked() {
    adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -q "mDreamingLockscreen=true"
}

if device_is_locked; then
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb shell input keyevent 82 >/dev/null 2>&1 || true
    adb shell input swipe 540 1800 540 600 >/dev/null 2>&1 || true
    sleep 1
fi

if device_is_locked; then
    log_error "${ANDROID_SERIAL:-The device} is showing a lock screen that cannot be dismissed from here, so Android will refuse the foreground service and nothing will be imported or synced."
    exit 1
fi

# --- 1. The database that already exists, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/existing-remote-origin"
log_info "The database that already exists: $S3_ORIGIN_PATH"

export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the database in the bucket with the CLI, with photos already in it"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-2.png" --db "$S3_ORIGIN_PATH" --yes || exit 1

ORIGIN_FILES_AT_START="$(origin_file_count)"
log_info "The database holds $ORIGIN_FILES_AT_START file(s) before the phone touches it"

# --- 2. A phone that knows about the bucket and nothing else. ---

if [ "$CAN_WIPE_APP_DATA" -eq 1 ]; then
    "${PLATFORM}_reset_app_state" || exit 1
else
    log_info "Running against a real device: borrowing its settings rather than wiping its data"
    mkdir -p "$SAVED_SETTINGS_DIR"
    android_save_sandbox_file "$CONFIG_FILE" "$SAVED_SETTINGS_DIR/$CONFIG_FILE"
    android_save_sandbox_file "$DATABASES_CONFIG_FILE" "$SAVED_SETTINGS_DIR/$DATABASES_CONFIG_FILE"
    android_save_app_data_file "$SECURE_STORE_FILE" "$SAVED_SETTINGS_DIR/secure-store.xml"
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
fi

# Anything an earlier run of this test left in the library, and the replica an earlier run made. A
# replication into a directory that already holds an unrelated database is refused.
adb shell "rm -f /sdcard/DCIM/psphere-existing-remote-*/*" >/dev/null 2>&1 || true
adb shell "rmdir /sdcard/DCIM/psphere-existing-remote-*" >/dev/null 2>&1 || true
"${PLATFORM}_remove_media_matching" "psphere-existing-remote-" || true
"${PLATFORM}_reset_path" "$DB_NAME"

# Only the remote is listed. This is the state the phone is in after "Receive database": it knows
# where the database is and which secret opens it, and holds no copy of it.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$REMOTE_DB_NAME\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

# One photo in the test's own album, so the album exists and can be asked for its id.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ANCHOR_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

TEST_ALBUM_ID="$(android_media_album_id "$ANCHOR_PHOTO_NAME")"
if [ -z "$TEST_ALBUM_ID" ]; then
    log_error "MediaStore did not file $ANCHOR_PHOTO_NAME under an album, so automatic import cannot be pointed at one."
    exit 1
fi
log_info "The test's photos are in album $TEST_ALBUM_ID ($TEST_ALBUM_DIR)"

"${PLATFORM}_grant_media_permission" || exit 1
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials for the bucket, added the way a user adds them. The entry seeded above names this
# secret, and credentials are resolved by exact path, so without it every read of the remote fails.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# --- 3. The app replicates the remote down as a partial replica. ---

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# The remote is the only entry, so its card's action menu is the only one on the page.
send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

# A partial replication copies the README, the files merkle tree and the record database's merkle
# trees, and deliberately does not walk the tree, so this is seconds however large the remote is.
wait_for_log "$TMP_DIR" "Replication completed for"
log_success "The app replicated the existing database down as a partial replica"

send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

# --- 4. The replica is registered and opened. ---
#
# By hand, because a replication does not register its destination on mobile. When
# plan-register-replica-in-database-list.md lands, this whole block becomes an assertion that the
# entry is already there.
# Away from the databases page and back, because navigating to the route the app is already on
# emits no render and the wait below would time out on a working app. Test 17 hops the same way.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"
wait_for_log "$TMP_DIR" "Database opened"
log_success "The replica is registered and open"

# --- 5. The remote's photos appear on the phone. ---
#
# The replication copied the trees and none of their contents. Opening a partial replica queues the
# prefetch that pulls the records and thumbnails down, so the gallery is empty until that has run.
# This is the slow step, and an empty gallery a minute in is the prefetch still working.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_value "$APP_PORT" database-photo-count "[1-9][0-9]* photos" "$PREFETCH_TIMEOUT_SECONDS"
log_success "The photos already in the remote are showing on the phone"

# --- 6. Automatic import and syncing, into the replica. ---
#
# Seeded rather than driven through the settings card for the reason test 50 gives: the card would
# make the app create a database of its own and watch the whole library, which has no origin to sync
# to and, on a phone, would import somebody's entire photo collection. The gaps are seeded short so
# the test is not waiting out the defaults several times over.
"${PLATFORM}_seed_auto_import_config" "true" "$DB_NAME" "5000" "$TEST_ALBUM_ID" || exit 1
"${PLATFORM}_seed_sync_config" "true" "false" "5000" "$DB_NAME" || exit 1

# Restarted so it reads the settings just written: nothing outside the app tells it a settings file
# has changed, and the loops start when the app finds automatic import on at launch.
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

SERVICE_STARTED=0
for _ in $(seq 1 60); do
    if auto_import_service_running; then
        SERVICE_STARTED=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_STARTED" -ne 1 ]; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported or synced."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service is running"

# The anchor photo, which is the first thing a pass takes in. The replica holds the remote's records
# but none of its originals, so every original in it is one this device imported.
wait_for_asset_count 1 || exit 1
log_success "Automatic import wrote into the replica rather than making a database of its own"

# --- 7. A photo taken now reaches the database that existed before the phone did. ---

ORIGIN_FILES_BEFORE_NEW_PHOTO="$(origin_file_count)"
log_info "The origin holds $ORIGIN_FILES_BEFORE_NEW_PHOTO file(s) before the new photo"

"${PLATFORM}_seed_media" "$NEW_PHOTO_SOURCE" "$NEW_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

wait_for_asset_count 2 || exit 1
wait_for_origin_growth "$ORIGIN_FILES_BEFORE_NEW_PHOTO" "A photo taken on the phone reached the existing database" || exit 1

# Nothing that was already in the bucket was lost by the phone joining it: the count only ever grew.
ORIGIN_FILES_AT_END="$(origin_file_count)"
if [ "${ORIGIN_FILES_AT_END:-0}" -lt "${ORIGIN_FILES_AT_START:-0}" ]; then
    log_error "The origin held $ORIGIN_FILES_AT_START file(s) before the phone joined it and holds $ORIGIN_FILES_AT_END now. Joining a phone to a database must only ever add to it."
    exit 1
fi
log_success "The database the phone joined still holds everything it started with"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 55 passed: existing-remote-auto-import"
