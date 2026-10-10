#!/bin/bash

# An S3 database whose bucket has become unreachable must surface an error in the app, not an empty gallery.
#
# This is the same class of fault test 25 guards against for the bucket browser, applied to opening a database. An empty gallery for an
# unreachable bucket is indistinguishable from a database with nothing in it, so a user looking at one cannot tell that their photos are
# still there and merely out of reach.
#
# The database is populated on a live server first, so the empty gallery this test is looking out for would definitely be wrong. On a
# desktop it is built through the app, then the emulator is stopped and the app restarted, so nothing in the process can be serving the
# assets from memory. On a phone it is built in the bucket from the host with the CLI and registered on the device, and the emulator is
# stopped before the app ever opens it, so nothing on the device can be serving it from a cache.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 28 "s3-failure"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-failure"

cleanup() {
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/failure"
log_info "Database path: $S3_DB_PATH"

case "$PLATFORM" in
    android|ios)
        # --- 1. Build a populated database in the bucket, from the host. ---

        # Isolate the host CLI's config and vault. Without this it reads the developer's real ones, and the CLI prefers a databases
        # entry's vault secret over the AWS_* variables below, so a same-named entry on the machine silently points these commands at a
        # different server.
        export PHOTOSPHERE_CONFIG_DIR="$TMP_DIR/host-config"
        export PHOTOSPHERE_VAULT_DIR="$TMP_DIR/host-vault"
        export PHOTOSPHERE_VAULT_TYPE="plaintext"

        # The host reaches the emulator on loopback; only the device needs the host address.
        export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
        export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
        export AWS_REGION="us-east-1"

        ( cd "$REPO_DIR/apps/cli" && bun run start -- init --db "$S3_DB_PATH" --yes ) || exit 1
        ( cd "$REPO_DIR/apps/cli" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$S3_DB_PATH" --yes ) || exit 1
        log_success "The bucket holds a database with one asset in it"

        # --- 2. Register it on the device, then take the server away. ---

        reset_app_state

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

        "${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$S3_DB_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

        log_info "Stopping the S3 emulator; the bucket is now unreachable from the device"
        stop_s3_emulator "$S3_STATE_DIR"
        ;;
    *)
        # --- 1. Build a populated S3 database while the server is up. ---

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

        send_command "$APP_PORT" menu '{"action":"new-database"}' || exit 1
        wait_for_log "$TMP_DIR" "Create database dialog opened"
        send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}" || exit 1
        send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}' || exit 1
        wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
        send_command "$APP_PORT" click '{"dataId":"select-s3-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Select secret modal ready"
        send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
        wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"
        send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}" || exit 1
        send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
        wait_for_log "$TMP_DIR" "Database created"

        send_command "$APP_PORT" menu '{"action":"open-database"}' || exit 1
        wait_for_log "$TMP_DIR" "Open database dialog opened"
        send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
        wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"
        send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Import page ready"
        send_command "$APP_PORT" pick-answer "{\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}" || exit 1
        send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
        wait_for_log "$TMP_DIR" "2 assets imported"

        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
        log_success "The database holds two assets while the server is up"

        # --- 2. Take the server away and restart the app. ---

        stop_app "$APP_PORT" "$TMP_DIR"
        log_info "Stopping the S3 emulator; the bucket is now unreachable"
        stop_s3_emulator "$S3_STATE_DIR"

        start_app "$TMP_DIR"
        # start_app truncates app.log, so the cursor has to go back to the top.
        reset_log_cursor "$TMP_DIR"
        wait_for_ready "$APP_PORT"
        ;;
esac

# --- 3. Opening it must report a failure, not an empty gallery. ---

send_command "$APP_PORT" menu '{"action":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

# Two outcomes are possible and only one of them is allowed, so this watches for both at once and stops at whichever arrives. The app
# must report a failure. What it must not do is finish the load reporting zero assets, which renders an empty gallery that looks exactly
# like an empty database. The two cannot both happen: openDatabase logs the failure and returns without setting the database path, so no
# load is started and the completion line cannot follow it. Whichever line appears first is the app's answer.
#
# The error has to be about this database, so it is matched on openDatabase's own message naming the database path and not on any
# [ERROR] line, which would pass on an unrelated error. The AWS SDK retries a connection several times before giving up, so this waits
# well past that: the question is whether the app ever says anything, not whether it says it quickly.
EXPECTED_ERROR="Could not reach the database at $S3_DB_PATH"
EMPTY_LOAD="Load assets task completed: 0 assets loaded"
ERROR_WAIT_SECONDS=90
error_deadline=$((SECONDS + ERROR_WAIT_SECONDS))
error_started=$SECONDS
while [ "$SECONDS" -lt "$error_deadline" ]; do
    if grep -qF "$EXPECTED_ERROR" "$TMP_DIR/app.log" 2>/dev/null; then
        log_success "The app did not report an empty-but-successful load from the unreachable bucket"
        log_success "The app reported an error for the unreachable bucket after $((SECONDS - error_started))s"
        stop_app "$APP_PORT" "$TMP_DIR"
        log_success "Test 28 passed: s3-failure"
        exit 0
    fi
    if grep -qF "$EMPTY_LOAD" "$TMP_DIR/app.log" 2>/dev/null; then
        log_error "The app reported a successful load of 0 assets from an unreachable bucket"
        log_error "There is data in that bucket; an empty gallery here is indistinguishable from an empty database"
        exit 1
    fi
    sleep "$WAIT_POLL_INTERVAL"
done

log_error "The app never logged \"$EXPECTED_ERROR\" in ${ERROR_WAIT_SECONDS}s"
log_error "It neither completed the load nor logged an error, so the user is left looking at a screen that never resolves"
log_error "Last 30 lines of app.log:"
tail -30 "$TMP_DIR/app.log"
exit 1
