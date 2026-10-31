#!/bin/bash

# Creates a database on S3 through the app, imports two images into it and reads it back, against a real S3 server (a local MinIO
# started by this test). On a desktop it then restarts the app and reads the database back again.
#
# The restart is the assertion that matters on a desktop. A gallery that loads two assets in the process the import ran in could be
# reading an in-process cache; a gallery that loads two assets after the app has been stopped and started again can only have got them
# out of the bucket. A phone does not restart the app: it covers creating, importing and reading back inside one run, which is what
# runs the create, import and load tasks over an s3: path inside the embedded worker.
#
# The credentials reach S3 through the vault secret named by the databases entry the dialog writes, so this also covers the vault
# credential path.
#
# The path is typed in the plain `s3:bucket/prefix` form. The dialog's own Browse S3 button produces the `s3:bucket:/prefix` form
# instead, and that form cannot be opened at all: nothing in the storage layer understands the `bucket:` segment (see
# apps/cli-zig/smoke-tests-zig/72-s3-paths, whose final section is left failing on that). Using the working form here keeps this test about the
# lifecycle.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 26 "s3-database-lifecycle"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-lifecycle"

# Stops the app and the emulator, so a failed assertion never leaves a MinIO server running. The emulator's stop is safe to call when
# nothing was started, so it goes in unconditionally.
cleanup() {
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/lifecycle"
log_info "Database path: $S3_DB_PATH"

# Creating a database on S3, and importing into it, are given longer than the default on a phone, because every step of either is a
# round trip to the host and on a NAT-only emulator those are slow enough to matter. The work is still going when a short wait gives
# up, and app.log stops meanwhile because the worker logs elsewhere, so the failure reads as a hang when it is not one.
S3_STEP_TIMEOUT=300

case "$PLATFORM" in
    android|ios)
        # Stage the two fixture images so only they (not the large archive and video siblings) are seeded.
        STAGE_DIR="$TMP_DIR/import-images"
        mkdir -p "$STAGE_DIR"
        cp "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png" "$STAGE_DIR/"

        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        reset_app_state
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        # Seed the two images into the sandbox import temp directory, which is where the picked paths point.
        "${PLATFORM}_seed_database" "$STAGE_DIR" ".import-tmp" || exit 1
        ;;
esac

# --- 1. Store the S3 credentials through the app's own Add Secret dialog. ---

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# --- 2. Create the database on S3 through the New Database dialog. ---

click_sidebar_item "$APP_PORT" new-database || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}" || exit 1

send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}' || exit 1

# The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
send_command "$APP_PORT" click '{"dataId":"select-s3-button"}' || exit 1
# Wait for the secret list to mount before picking from it. Clicking straight through leaves the chosen secret as "None selected" when
# the machine is slow, because the click lands before the modal renders its buttons.
wait_for_log "$TMP_DIR" "Select secret modal ready"
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created" "$S3_STEP_TIMEOUT"
log_success "The database was created on S3 through the app"

# --- 3. Open it and import two files. ---

case "$PLATFORM" in
    android|ios)
        # Creating the database opens it, so there is no open step here. Opening it a second time would cancel the task source the
        # first open established, and the worker pool remembers a cancelled source, so the load queued against it is dropped and never
        # completes.
        ;;
    *)
        click_sidebar_item "$APP_PORT" open-database || exit 1
        wait_for_log "$TMP_DIR" "Open database dialog opened"
        send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
        ;;
esac
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

# Opening a database leaves whatever page was showing on screen, and this test was last on the secrets page, so the gallery (which is
# where the Import button lives) has to be navigated to.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"
case "$PLATFORM" in
    android|ios)
        # Answer the picker with the staged paths, then press the button that opens it, so the import runs and writes every asset it
        # produces into the bucket from the embedded worker.
        send_command "$APP_PORT" pick-answer "$(jq -cn --arg first "$("${PLATFORM}_app_path" ".import-tmp/test-1.jpeg")" --arg second "$("${PLATFORM}_app_path" ".import-tmp/test-2.png")" '{paths: [$first, $second]}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
        ;;
    *)
        send_command "$APP_PORT" pick-answer "{\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}" || exit 1
        send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
        ;;
esac
wait_for_log "$TMP_DIR" "2 assets imported" "$S3_STEP_TIMEOUT"

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The imported assets are shown in the gallery"

case "$PLATFORM" in
    android|ios)
        # Thumbnail fetches for freshly imported assets go through the asset-serving layer; ignore only those.
        check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'
        stop_app "$APP_PORT" "$TMP_DIR"
        ;;
    *)
        # --- 4. The database's own details page loads for an S3 database. ---

        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"
        send_command "$APP_PORT" click '{"dataId":"view-database-button"}' || exit 1
        wait_for_log "$TMP_DIR" "View database dialog opened"
        log_success "The database details loaded for an S3 database"

        # --- 5. Restart the app and read the database back out of the bucket. ---

        stop_app "$APP_PORT" "$TMP_DIR"
        log_info "Restarting the app; the gallery below can only come from the bucket"
        start_app "$TMP_DIR"
        # start_app truncates app.log, so the cursor has to go back to the top or every wait below looks past the end of the new log.
        reset_log_cursor "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # The app reopens the last database by itself on start. Its load is waited for here, so the load waited for after the click is the
        # one the click started. Otherwise that wait can match the reopen's load, which finished before the click, and the navigation
        # below lands straight after the click, while the app's own redirect from "/" to the gallery can still be pending. Navigating to
        # "/" then replaces that redirect with the route already showing, and the gallery never mounts.
        wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded"

        click_sidebar_item "$APP_PORT" open-database || exit 1
        wait_for_log "$TMP_DIR" "Open database dialog opened"
        send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
        wait_for_log "$TMP_DIR" "Opening database"
        wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded"

        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
        log_success "The assets came back out of the bucket after a restart"

        check_no_errors "$TMP_DIR"

        stop_app "$APP_PORT" "$TMP_DIR"
        ;;
esac

log_success "Test 26 passed: s3-database-lifecycle"
