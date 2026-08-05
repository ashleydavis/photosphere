#!/bin/bash

# Creates a database on S3 through the app, imports into it, reads it back, restarts the app and
# reads it back again, against a real S3 server (a local MinIO started by this test).
#
# Desktop S3 support was previously proven only as far as listing a bucket: test 25 browses a seeded
# bucket from the New Database dialog and then cancels, so no desktop code path had ever written a
# byte to S3 under test. This does the whole lifecycle through the UI.
#
# The restart is the assertion that matters. A gallery that loads two assets in the same process the
# import ran in could be reading an in-process cache; a gallery that loads two assets after the app has
# been stopped and started again can only have got them out of the bucket.
#
# The credentials reach S3 through the vault secret named by the databases entry the dialog writes, so
# this also covers the desktop side of the vault credential path.
#
# The path is typed in the plain `s3:bucket/prefix` form. The dialog's own Browse S3 button produces
# the `s3:bucket:/prefix` form instead, and that form cannot be opened at all: nothing in the storage
# layer understands the `bucket:` segment (see apps/cli/smoke-tests/72-s3-paths, whose final section is
# left failing on that). Using the working form here keeps this test about the lifecycle.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../../.." && native_pwd)"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 26 "s3-database-lifecycle"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-lifecycle"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running. The
# emulator's stop is safe to call when nothing was started, so it goes in unconditionally.
cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/desktop-lifecycle"
log_info "Database path: $S3_DB_PATH"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# --- 1. Store the S3 credentials through the app's own Add Secret dialog. ---

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY"

# --- 2. Create the database on S3 through the New Database dialog. ---

send_command "$APP_PORT" menu '{"itemId":"new-database"}'
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}"

send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}'
send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}'

# The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
send_command "$APP_PORT" click '{"dataId":"select-s3-button"}'
wait_for_log "$TMP_DIR" "Select secret modal ready"
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}'
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}"
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}'
wait_for_log "$TMP_DIR" "Database created"
log_success "The database was created on S3 through the app"

# --- 3. Open it and import two files. ---

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

# Opening a database leaves whatever page was showing on screen, and this test was last on the
# secrets page, so the gallery (which is where the Import button lives) has to be navigated to.
send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"

send_command "$APP_PORT" click '{"dataId":"import-button"}'
wait_for_log "$TMP_DIR" "Import page ready"
send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}"
wait_for_log "$TMP_DIR" "2 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The imported assets are shown in the gallery"

# --- 4. The database's own details page loads for an S3 database. ---

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"
send_command "$APP_PORT" click '{"dataId":"view-database-button"}'
wait_for_log "$TMP_DIR" "View database dialog opened"
log_success "The database details loaded for an S3 database"

# --- 5. Restart the app and read the database back out of the bucket. ---

stop_app "$APP_PORT" "$TMP_DIR"
log_info "Restarted the app; the gallery below can only come from the bucket"
start_app "$TMP_DIR"
# start_app truncates app.log, so the cursor has to go back to the top or every wait below looks past
# the end of the new log.
reset_log_cursor "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The assets came back out of the bucket after a restart"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 26 passed: s3-database-lifecycle"
