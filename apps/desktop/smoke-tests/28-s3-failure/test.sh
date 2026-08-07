#!/bin/bash

# An S3 database whose bucket has become unreachable must surface an error in the app, not an empty
# gallery.
#
# This is the same class of fault test 25 guards against for the bucket browser, applied to opening a
# database. An empty gallery for an unreachable bucket is indistinguishable from a database with
# nothing in it, so a user looking at one cannot tell that their photos are still there and merely out
# of reach.
#
# The database is created and populated on a live server first, so the empty gallery this test is
# looking out for would definitely be wrong: there are two assets in that bucket. The emulator is then
# stopped and the app restarted, so nothing in the process can be serving the assets from memory.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../../.." && native_pwd)"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 28 "s3-failure"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-failure"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/desktop-failure"
log_info "Database path: $S3_DB_PATH"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# --- 1. Build a populated S3 database while the server is up. ---

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY"

send_command "$APP_PORT" menu '{"itemId":"new-database"}'
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}"
send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}'
send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}'
wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
send_command "$APP_PORT" click '{"dataId":"select-s3-button"}'
wait_for_log "$TMP_DIR" "Select secret modal ready"
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}'
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}"
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}'
wait_for_log "$TMP_DIR" "Database created"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"
send_command "$APP_PORT" click '{"dataId":"import-button"}'
wait_for_log "$TMP_DIR" "Import page ready"
send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}"
wait_for_log "$TMP_DIR" "2 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The database holds two assets while the server is up"

# --- 2. Take the server away and reopen the database. ---

stop_app "$APP_PORT" "$TMP_DIR"
log_info "Stopping the S3 emulator; the bucket is now unreachable"
stop_s3_emulator "$S3_STATE_DIR"

start_app "$TMP_DIR"
# start_app truncates app.log, so the cursor has to go back to the top.
reset_log_cursor "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'

# The app must report a failure. The alternative it must not do is finish the load reporting zero
# assets, which renders an empty gallery that looks exactly like an empty database.
#
# wait_for_log exits on timeout rather than returning, so it runs in a subshell here: the exit ends
# the subshell and this test sees the non-zero status, instead of disappearing before it can say what
# went wrong.
if ( wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded" 30 ); then
    log_error "The app reported a successful load of 0 assets from an unreachable bucket"
    log_error "There are two assets in that bucket; an empty gallery here is indistinguishable from an empty database"
    exit 1
fi
log_success "The app did not report an empty-but-successful load from the unreachable bucket"

# Falls through to the error check below, which decides the test.

# Something has to say the load failed, and it has to be about THIS database. The AWS SDK retries a
# connection several times before giving up, so this waits well past that rather than deciding after
# one look: the question is whether the app EVER says anything, not whether it says it quickly.
#
# Matched on openDatabase's own message naming the database path, not on any [ERROR] line that is not
# the Chromium dbus one. That older check passed on any unrelated error the app happened to log, so it
# could report "the app reported an error for the unreachable bucket" for an error about something
# else entirely, which is exactly the confusion this test exists to prevent.
EXPECTED_ERROR="Could not reach the database at $S3_DB_PATH"
ERROR_WAIT_SECONDS=90
error_elapsed=0
while [ "$error_elapsed" -lt "$ERROR_WAIT_SECONDS" ]; do
    if grep -qF "$EXPECTED_ERROR" "$TMP_DIR/app.log" 2>/dev/null; then
        log_success "The app reported an error for the unreachable bucket after ${error_elapsed}s"
        stop_app "$APP_PORT" "$TMP_DIR"
        log_success "Test 28 passed: s3-failure"
        exit 0
    fi
    sleep 1
    error_elapsed=$((error_elapsed + 1))
done

log_error "The app never logged \"$EXPECTED_ERROR\" in ${ERROR_WAIT_SECONDS}s"
log_error "It neither completed the load nor logged an error, so the user is left looking at a screen that never resolves"
log_error "Last 30 lines of app.log:"
tail -30 "$TMP_DIR/app.log"
exit 1
