#!/bin/bash

# Both off switches hold: with automatic import off, a photo copied into the watched folder stays out of the database, and with
# syncing off, nothing reaches the origin. Each is the negative case a scenario that only checked the "on" side would pass on an app
# that ignored the setting, and the sync one is checked from the origin so a quiet app cannot hide work it did anyway.
#
# The pass gap is seeded short (pause_between_runs_ms), so each wait is a couple of passes rather than the thirty second default
# several times over. The database is read from its own files and the origin from the host.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 70 "switches-off"

# Not on iOS. iOS runs its passes when the system decides, and the only way to force one is an lldb command this harness has no way to
# issue on Xcode 14.2.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: the off switches are covered on Android and the desktop only, where a pass can be made to run."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

"${PLATFORM}_claim_device" || exit 1

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="switches-off-smoke-test-s3"

# The database automatic import writes into, named for the scenario rather than "photosphere-default" so a real mobile is never pushed
# into its own database. The path is the absolute one in the app's files directory.
DB_NAME="switches-off-test-db"
DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"

# The watched folder, which automatic import is pointed at and nothing else.
LIBRARY_PREFIX="psphere-switches-off"
LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"

# The photos put into the watch folder, named so a parallel run cannot collide with them.
ANCHOR_PHOTO_NAME="psphere-switches-off-anchor-$$.jpeg"
OFF_PHOTO_NAME="psphere-switches-off-off-$$.png"

# The gap between passes, short so two passes is a few seconds.
PASS_GAP_MS=1000

# How long to watch for something that must NOT happen, several passes at the seeded gap.
ABSENT_WINDOW_SECONDS=20

#
# How many originals the app's database holds right now, or 0 when there is no database yet.
#
asset_count() {
    "${PLATFORM}_asset_count" "$DB_NAME"
}

#
# How many files the origin database in the bucket holds.
#
origin_file_count() {
    run_zig_cli "$TMP_DIR" summary --db "$S3_ORIGIN_PATH" --yes 2>/dev/null \
        | tr -d '\r' \
        | grep "Total files:" \
        | grep -o '[0-9][0-9]*' \
        | head -1
}

#
# Waits until the app's database holds at least the given number of originals.
#
wait_for_asset_count() {
    local expected="$1"
    local elapsed=0
    while [ "$elapsed" -lt 120 ]; do
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

on_exit() {
    local exit_code=$?
    "${PLATFORM}_library_remove" "$LIBRARY" "$ANCHOR_PHOTO_NAME" "$OFF_PHOTO_NAME" 2>/dev/null || true
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap on_exit EXIT

mkdir -p "$TMP_DIR"

# --- 1. The origin database, in a bucket on this machine, and a partial replica of it. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/switches-off-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used directly here.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT_URL="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

run_zig_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
# Not the photo automatic import later takes in: an import recognises a photo the database already holds and does not take it in again.
run_zig_cli "$TMP_DIR" add "$REPO_DIR/test/duplicate-images/a.png" --db "$S3_ORIGIN_PATH" --yes || exit 1

# A replica rather than a fresh database, because sync moves content between two databases that are copies of each other.
LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
run_zig_cli "$TMP_DIR" replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes || exit 1
# The sync plan reads this to find there is somewhere to sync to, and the sync handler reads it to find where.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

ORIGIN_FILES_AT_START="$(origin_file_count)"
log_info "The origin holds $ORIGIN_FILES_AT_START file(s) before the app runs"

# --- 2. The replica into the app, with automatic import on and syncing off. ---

"${PLATFORM}_reset_app_state" || exit 1
"${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1
# Both databases are registered: the on-device replica and its origin. Credentials are resolved by exact path.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"},{\"name\":\"$DB_NAME-origin\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1
# A desktop syncs the database that is open; a mobile's loops work on the database the settings name.
"${PLATFORM}_open_database_on_launch" "$DB_PATH" || exit 1

# The anchor photo sits in the watched folder before the app starts, so it is the first thing a pass takes in.
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ANCHOR_PHOTO_NAME" || exit 1

# The photo and notification permissions, from outside the app, which a mobile needs before the pass can read the library or hold the
# foreground service.
"${PLATFORM}_grant_media_permission" || exit 1
"${PLATFORM}_grant_notification_permission" || exit 1

# Automatic import on, syncing off, both at the short gap.
"${PLATFORM}_seed_library_auto_import_config" "true" "$DB_PATH" "$PASS_GAP_MS" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1
"${PLATFORM}_seed_sync_config" "false" "false" "$PASS_GAP_MS" "$DB_PATH" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials for the bucket, added the way a user adds them, so the sync below is refused on the switch and not on a missing
# secret. Without them an app that ignored the off switch would push nothing either way and this could not tell the two apart.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# --- 3. With syncing off, the imported photo still reaches the database, and nothing reaches the origin. ---

wait_for_asset_count 1 || exit 1
log_success "A photo was imported while syncing was off, so the database is not what is being stopped"

ELAPSED=0
while [ "$ELAPSED" -lt "$ABSENT_WINDOW_SECONDS" ]; do
    CURRENT="$(origin_file_count)"
    if [ "${CURRENT:-0}" -gt "${ORIGIN_FILES_AT_START:-0}" ]; then
        log_error "The origin grew from $ORIGIN_FILES_AT_START to $CURRENT file(s) while syncing was switched off."
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
log_success "Nothing reached the origin while syncing was switched off"

# --- 4. With automatic import off, a new photo stays out of the database. ---

stop_app "$APP_PORT" "$TMP_DIR"
"${PLATFORM}_seed_library_auto_import_config" "false" "$DB_PATH" "$PASS_GAP_MS" "$LIBRARY" "$ANCHOR_PHOTO_NAME" || exit 1
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-2.png" "$OFF_PHOTO_NAME" || exit 1

reset_log_cursor "$TMP_DIR"
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

ELAPSED=0
while [ "$ELAPSED" -lt "$ABSENT_WINDOW_SECONDS" ]; do
    if [ "$(asset_count)" -gt 1 ]; then
        log_error "A new photo was imported while automatic import was switched off: the database grew to $(asset_count) original(s)."
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
log_success "A photo copied into the watched folder stayed out while automatic import was switched off"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 70 passed: switches-off"