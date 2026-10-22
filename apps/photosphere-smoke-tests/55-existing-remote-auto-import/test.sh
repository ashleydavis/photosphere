#!/bin/bash

# Joining a phone to a database that already exists, and then importing and syncing into it.
#
# The other way round from the other automatic import and background scenarios, which all start from a phone with nothing and build its
# database up. Here the database exists first, in a bucket, with photos already in it, and the phone joins it by taking a copy: the
# credentials go in, the app replicates the remote down as a partial replica, and automatic import and background syncing then run
# against that copy. This is what somebody who already has a Photosphere database does when they install the app on a phone.
#
# The replication is driven through the app's own Replicate dialog rather than being done from the host with the CLI, which is what the
# background-sync scenario does. That is the point of this one: the joining step is the one that is new, and doing it from the host
# would test a route no user has.
#
# What reaches the bucket is read from the host with the CLI, never from anything the app says, for the reason the background-sync
# scenario gives: a backgrounded page may have its connection to the host suspended, and the bucket keeps answering either way.
#
# It runs against a real phone as well as an emulator, and on a phone it never wipes anything: an emulator gets `pm clear`, a phone gets
# its settings files and its keychain saved and handed back.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 55 "existing-remote-auto-import"

# Not on iOS. The photo permission can be granted from outside the app there (ios_grant_media_permission), but what this scenario counts
# cannot be pinned to its own photos. The iOS native app lists every library item with no album, so automatic import there cannot be
# pointed at the scenario's photos and imports the whole library, which already holds the simulator's own photos: the replica would pass
# both of its asset counts before either of this scenario's photos was imported. And the simulator has no supported way to take a seeded
# photo back out of its library, so every run would leave its photos for the next. Many of the helpers this scenario calls have no iOS
# version either.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: on iOS automatic import cannot be pointed at this scenario's own photos, so its counts could not fail, and a seeded photo cannot be removed from the simulator's library."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

"${PLATFORM}_claim_device" || exit 1

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="existing-remote-smoke-test-s3"

# The name and path of the replica the app makes. Named for the scenario rather than "photosphere-default" so a run against a real
# phone never touches the database that phone backs up to. The app resolves no relative path against its storage, so the path is the
# absolute one in the app's files directory.
DB_NAME="existing-remote-test-db"
DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"

# The name the remote is listed under on the phone. Different from the replica's, because entry names have to be unique and both are in
# the list at once.
REMOTE_DB_NAME="existing-remote-test-origin"

# True when this run is against a real phone rather than an emulator.
IS_REAL_DEVICE=0
if "${PLATFORM}_is_real_device"; then
    IS_REAL_DEVICE=1
fi

# The photos put into the device library, named so a parallel run cannot collide with them.
ANCHOR_PHOTO_NAME="psphere-existing-remote-anchor-$$.jpeg"

# The photo taken "now", after everything is settled. Small on a phone: a phone reaches the host through the port reverses adb sets up
# over USB, and a large upload through that tunnel times out.
if [ "$IS_REAL_DEVICE" -eq 1 ]; then
    NEW_PHOTO_NAME="psphere-existing-remote-new-$$.png"
    NEW_PHOTO_SOURCE="$REPO_DIR/test/test.png"
else
    NEW_PHOTO_NAME="psphere-existing-remote-new-$$.jpg"
    NEW_PHOTO_SOURCE="$REPO_DIR/test/test.jpg"
fi

# The scenario's own library, which automatic import is pointed at and nothing else. Watching the whole library would import somebody's
# entire photo collection into this scenario's database on a phone.
LIBRARY_PREFIX="psphere-existing-remote"
LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"

# How long to wait for a photo to reach the origin. A pass has an import pass to wait behind, a database to open and a bucket to talk to.
SYNC_TIMEOUT_SECONDS=240

# How long to wait for the prefetch to bring the remote's records and thumbnails down. This is the slow step of the whole flow: a partial
# replication copies the merkle trees and nothing else, and opening the replica is what starts the fetch of everything they describe.
PREFETCH_TIMEOUT_SECONDS=180

#
# How many originals the app's replica holds right now, or 0 when there is no database yet.
#
asset_count() {
    "${PLATFORM}_asset_count" "$DB_NAME"
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

# Where the device's own settings are kept while this scenario has its own in place. Real phones only.
SAVED_SETTINGS_DIR="$TMP_DIR/device-settings"

CAN_WIPE_APP_DATA=0
if "${PLATFORM}_may_wipe_app_data"; then
    CAN_WIPE_APP_DATA=1
fi

on_exit() {
    local exit_code=$?
    "${PLATFORM}_screen_on" >/dev/null 2>&1 || true
    "${PLATFORM}_library_remove" "$LIBRARY" "$ANCHOR_PHOTO_NAME" "$NEW_PHOTO_NAME" 2>/dev/null || true
    cleanup_apps "$TMP_DIR"

    if [ "$CAN_WIPE_APP_DATA" -ne 1 ]; then
        "${PLATFORM}_return_app_settings" "$SAVED_SETTINGS_DIR"
        log_info "Left behind on this device: the test replica at files/$DB_NAME, which nothing reads once the settings above are back."
    fi

    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap on_exit EXIT

mkdir -p "$TMP_DIR"

# A locked phone refuses the foreground service this scenario needs, whatever else is true.
"${PLATFORM}_require_unlocked" || exit 1

# --- 1. The database that already exists, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/existing-remote-origin"
log_info "The database that already exists: $S3_ORIGIN_PATH"

export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

# None of these may be a photo this scenario later puts into the device photo library. An import recognises a photo the database already
# holds and does not take it in again, which is correct and is what the counts below would then be waiting forever for: seeding the
# phone the same file as the origin's first photo left the replica at zero originals through every pass, because there was nothing for
# automatic import to do.
log_info "Creating the database in the bucket with the CLI, with photos already in it"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/duplicate-images/a.png" --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-2.png" --db "$S3_ORIGIN_PATH" --yes || exit 1

ORIGIN_FILES_AT_START="$(origin_file_count)"
log_info "The database holds $ORIGIN_FILES_AT_START file(s) before the phone touches it"

# --- 2. A phone that knows about the bucket and nothing else. ---

if [ "$CAN_WIPE_APP_DATA" -eq 1 ]; then
    "${PLATFORM}_reset_app_state" || exit 1
else
    log_info "Running against a real device: borrowing its settings rather than wiping its data"
    "${PLATFORM}_borrow_app_settings" "$SAVED_SETTINGS_DIR" || exit 1
fi

# Anything an earlier run of this scenario left in the library, and the replica an earlier run made. A replication into a directory
# that already holds an unrelated database is refused.
"${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1
"${PLATFORM}_reset_path" "$DB_NAME" || exit 1

# Only the remote is listed. This is the state the phone is in after "Receive database": it knows where the database is and which
# secret opens it, and holds no copy of it.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$REMOTE_DB_NAME\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

# One photo in the scenario's own library, so the library exists and the device can be asked about it.
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ANCHOR_PHOTO_NAME" || exit 1

"${PLATFORM}_grant_media_permission" || exit 1
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials for the bucket, added the way a user adds them. The entry seeded above names this secret, and credentials are
# resolved by exact path, so without it every read of the remote fails.
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

send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

# A partial replication copies the README, the files merkle tree and the record database's merkle trees, and deliberately does not walk
# the tree, so this is seconds however large the remote is.
wait_for_log "$TMP_DIR" "Replication completed for"
log_success "The app replicated the existing database down as a partial replica"

send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

# --- 4. The replica is registered by the replication, and is opened. ---
#
# A replication that worked registers its destination in the databases list, so nothing has to be added by hand. The entry is read
# back from the settings file the app wrote, by the name the replica was given.
REGISTERED_ENTRY_FOUND=0
for _ in $(seq 1 30); do
    if "${PLATFORM}_read_databases_config" | grep -qF "name = \"$DB_NAME\""; then
        REGISTERED_ENTRY_FOUND=1
        break
    fi
    sleep 1
done
if [ "$REGISTERED_ENTRY_FOUND" -ne 1 ]; then
    log_error "The replication did not register the replica in the databases list. The list holds:"
    "${PLATFORM}_read_databases_config"
    exit 1
fi
log_success "The replication registered the replica"

# Opened from the open-database dialog, where the remote is the first entry and the replica the second.
click_sidebar_item "$APP_PORT" open-database || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-1"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened"
log_success "The replica is open"

# --- 5. The remote's photos appear on the phone. ---
#
# The replication copied the trees and none of their contents. Opening a partial replica queues the prefetch that pulls the records and
# thumbnails down, so the gallery is empty until that has run. This is the slow step, and an empty gallery a minute in is the prefetch
# still working.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_value_matching "$APP_PORT" database-photo-count "[1-9][0-9]* photos" "$PREFETCH_TIMEOUT_SECONDS"
log_success "The photos already in the remote are showing on the phone"

# --- 6. Automatic import and syncing, into the replica. ---
#
# Seeded rather than driven through the settings card: the card would make the app create a database of its own and watch the whole
# library, which has no origin to sync to and, on a phone, would import somebody's entire photo collection. The gaps are seeded short so
# the scenario is not waiting out the defaults several times over.
"${PLATFORM}_seed_library_auto_import_config" "true" "$DB_PATH" "5000" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1
"${PLATFORM}_seed_sync_config" "true" "false" "1000" "$DB_PATH" || exit 1

# A desktop syncs the database that is open, so the replica is the one it opens when it starts. A phone's background loops work on the
# database the settings name and need nothing open.
"${PLATFORM}_open_database_on_launch" "$DB_PATH" || exit 1

restart_app

SERVICE_STARTED=0
for _ in $(seq 1 60); do
    if "${PLATFORM}_background_work_running"; then
        SERVICE_STARTED=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_STARTED" -ne 1 ]; then
    log_error "The foreground service is not running while automatic import is switched on. Nothing will be imported or synced."
    "${PLATFORM}_dump_background_diagnostics"
    exit 1
fi
log_info "The foreground service is running"

# The anchor photo, which is the first thing a pass takes in. The replica holds the remote's records but none of its originals, so every
# original in it is one this device imported.
wait_for_asset_count 1 || exit 1
log_success "Automatic import wrote into the replica rather than making a database of its own"

# --- 7. A photo taken now reaches the database that existed before the phone did. ---

ORIGIN_FILES_BEFORE_NEW_PHOTO="$(origin_file_count)"
log_info "The origin holds $ORIGIN_FILES_BEFORE_NEW_PHOTO file(s) before the new photo"

"${PLATFORM}_library_add" "$LIBRARY" "$NEW_PHOTO_SOURCE" "$NEW_PHOTO_NAME" || exit 1

wait_for_asset_count 2 || exit 1
wait_for_origin_growth "$ORIGIN_FILES_BEFORE_NEW_PHOTO" "A photo taken on the phone reached the existing database" || exit 1

# Nothing that was already in the bucket was lost by the phone joining it: the count only ever grew.
ORIGIN_FILES_AT_END="$(origin_file_count)"
if [ "${ORIGIN_FILES_AT_END:-0}" -lt "${ORIGIN_FILES_AT_START:-0}" ]; then
    log_error "The origin held $ORIGIN_FILES_AT_START file(s) before the phone joined it and holds $ORIGIN_FILES_AT_END now. Joining a phone to a database must only ever add to it."
    exit 1
fi
log_success "The database the phone joined still holds everything it started with"

# The fixture photo test.jpg carries GPS tags whose fractions are all 0/0, which the importer reports as out of range at error level
# and then ignores, so that report is ignored along with the thumbnail fetches; any other error fails the scenario.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 55 passed: existing-remote-auto-import"
