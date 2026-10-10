#!/bin/bash

# Browses an S3 bucket from the dialog that adds a database, against a real S3 server.
#
# The server is a local MinIO started by this test on an OS-assigned port over plain HTTP, so the test needs no credentials, no account
# and no configuration, and can never skip. It asserts two behaviours:
#
#   1. A populated bucket lists its seeded directories by name. This covers listing the top of a bucket (an empty key), which the
#      storage layer used to reject before the request was sent.
#   2. A bad credential surfaces an error in the browser rather than an empty list. An empty list is the failure this test exists to
#      catch: it looks exactly like an empty bucket.
#
# On a desktop the dialog is New Database, reached from the menu. On a phone it is Add Database, reached from the databases page's
# actions menu, and each listing runs as a background task on the embedded worker, so the second browse also covers the worker pool
# reviving a task source the first browser closed and cancelled.
#
# The endpoint given to the app is an IP address on purpose. Without path-style addressing the SDK puts the bucket into the hostname
# (`bucket.localhost`), which on a machine that resolves *.localhost reaches the server but lists nothing at all: assertion 1 then
# fails with an empty browser, which is precisely the silent wrong answer this test is here to prevent.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 25 "s3-database"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"

# Stops the app and the emulator, so a failed assertion never leaves a MinIO server running. The emulator's stop is safe to call when
# nothing was started, so it goes in unconditionally.
cleanup() {
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# Start the S3 server and read back the port it bound, the bucket it seeded and its credentials.
start_s3_emulator "$S3_STATE_DIR"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        reset_app_state
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add the S3 credentials through the app's own Add Secret dialog, the way a user would, rather than writing the vault file directly.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

#
# Opens the dialog that adds a database, switches it to S3, picks the secret, and opens the S3 browser on the seeded bucket. Leaves the
# browser open with its listing loading.
#
open_s3_browser() {
    case "$PLATFORM" in
        android|ios)
            send_command "$APP_PORT" navigate '{"page":"databases"}' || return 1
            wait_for_log "$TMP_DIR" "Databases page loaded"
            send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || return 1
            send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || return 1
            wait_for_log "$TMP_DIR" "Add database dialog opened"
            ;;
        *)
            send_command "$APP_PORT" menu '{"action":"new-database"}' || return 1
            wait_for_log "$TMP_DIR" "Create database dialog opened"
            ;;
    esac

    send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}' || return 1
    send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}' || return 1

    # The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
    wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
    send_command "$APP_PORT" click '{"dataId":"select-s3-button"}' || return 1
    # The modal loads its secrets before it renders any of them, so its button does not exist for a moment after the click above. A
    # click sent at once finds nothing and does nothing.
    wait_for_log "$TMP_DIR" "Select secret modal ready"
    send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || return 1
    wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

    send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || return 1
    # The browser's Cancel button says it has mounted: the type command below does not wait for its target, so typing into a modal that
    # has not mounted yet would go nowhere.
    wait_for_value "$APP_PORT" "s3-browser-cancel" "Cancel"

    # The listing loads on the bucket field changing; there is no separate list button.
    send_command "$APP_PORT" type "{\"dataId\":\"s3-browser-bucket-input\",\"text\":\"$S3_EMULATOR_BUCKET\"}" || return 1
}

#
# Cancels the S3 browser and then the dialog under it, so the next pass starts from a clean form.
#
close_s3_browser() {
    send_command "$APP_PORT" click '{"dataId":"s3-browser-cancel"}' || exit 1
    case "$PLATFORM" in
        android|ios)
            send_command "$APP_PORT" click '{"dataId":"add-database-cancel"}' || exit 1
            ;;
        *)
            send_command "$APP_PORT" click '{"dataId":"create-database-cancel"}' || exit 1
            ;;
    esac
}

#
# Waits for a listed directory entry, and on failure reports the browser's own error text before failing the test. Without that the
# only evidence of a failed listing is an empty element.
#
# wait_for_value exits on timeout rather than returning, so it runs in a subshell here: the exit ends the subshell and this function
# sees the non-zero status, instead of the whole test disappearing before it can say what went wrong.
# Usage: expect_listed_dir <index> <expected-name>
#
expect_listed_dir() {
    local entry_index="$1"
    local expected_name="$2"
    if ( wait_for_value "$APP_PORT" "s3-browser-dir-$entry_index" "$expected_name" 60 ); then
        return 0
    fi
    log_error "S3 browser error text was: $(read_value "$APP_PORT" "s3-browser-error")"
    exit 1
}

# --- 1. A populated bucket lists its seeded directories by name. ---

open_s3_browser || exit 1

# Each entry renders with a trailing slash ("alpha-dir/"), so match on the name as a prefix. Failing here means the listing came back
# empty or in a different order, both of which are real faults.
expect_listed_dir 0 "alpha-dir"
expect_listed_dir 1 "beta-dir"
log_success "Seeded directories listed from the bucket root"

close_s3_browser

# --- 2. A bad credential surfaces an error, not an empty list. ---

# Break the stored credentials through the app's own Edit Secret dialog. On a desktop no navigation is needed: the dialog that adds a
# database is a modal over whatever page is showing, so cancelling it leaves the secrets page on screen, and navigating to the page it
# is already on logs nothing, so a wait for "Secrets page loaded" would time out. A phone is on the databases page, and the secret's
# actions are in its card's menu.
case "$PLATFORM" in
    android|ios)
        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-s3-access-key-input","text":"WRONGACCESSKEY"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"secret-s3-secret-key-input","text":"WRONGSECRETKEY"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

open_s3_browser || exit 1

# The browser must say the listing failed. An empty list here would render "No sub-directories found here." and look exactly like an
# empty bucket, which is the fault this assertion exists to catch.
if ! ( wait_for_value "$APP_PORT" "s3-browser-error" "Failed to list directories" 60 ); then
    log_error "The S3 browser showed no error for bad credentials (an empty list is not an error)"
    log_error "First listed entry was: $(read_value "$APP_PORT" "s3-browser-dir-0")"
    exit 1
fi
log_success "Bad credentials surfaced an error rather than an empty list"

close_s3_browser

# The failed listing above is provoked on purpose and is logged by whatever lists the directories (the core on a desktop, the worker
# task on a phone), so it is the one error allowed through. Anything else in app.log still fails the test.
case "$PLATFORM" in
    android|ios)
        check_no_errors "$TMP_DIR" 'Failed to list directories|list-s3-dirs'
        ;;
    *)
        check_no_errors "$TMP_DIR" 'Error listing S3 directories'
        ;;
esac

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 25 passed: s3-database"
