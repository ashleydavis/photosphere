#!/bin/bash

# Browses an S3 bucket from the New Database dialog, against a real S3 server.
#
# The server is a local MinIO started by this test on an OS-assigned port over plain HTTP, so the
# test needs no credentials, no account and no configuration, and can never skip. It asserts two
# behaviours:
#
#   1. A populated bucket lists its seeded directories by name. This covers listing the *top* of a
#      bucket (an empty key), which the storage layer used to reject before the request was sent.
#   2. A bad credential surfaces an error in the browser rather than an empty list. An empty list is
#      the failure this test exists to catch: it looks exactly like an empty bucket.
#
# The endpoint given to the app is `http://localhost:<port>` on purpose. Without path-style
# addressing the SDK puts the bucket into the hostname (`bucket.localhost`), which on a machine that
# resolves *.localhost reaches the server but lists nothing at all: assertion 1 then fails with an
# empty browser, which is precisely the silent-wrong-answer this test is here to prevent.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && native_pwd)"

print_test_header 25 "s3-database"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running. The
# emulator's stop is safe to call when nothing was started, so it goes in unconditionally.
cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
    (cd "$REPO_ROOT" && bun run s3-emulator stop "$S3_STATE_DIR") >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

# Start the S3 server and read back the port it bound, the bucket it seeded and its credentials.
if ! (cd "$REPO_ROOT" && bun run s3-emulator start "$S3_STATE_DIR"); then
    log_error "Could not start the local S3 emulator"
    exit 1
fi
# shellcheck disable=SC1090
source "$S3_STATE_DIR/env"
S3_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
log_info "S3 emulator at $S3_ENDPOINT, bucket $S3_EMULATOR_BUCKET"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add the S3 credentials through the app's own Add Secret UI, the way a user would, rather than
# writing the vault file directly. The type defaults to s3-credentials, so no type switch is needed.
send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" type "{\"dataId\":\"secret-name-input\",\"text\":\"$SECRET_NAME\"}"
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-endpoint-input\",\"text\":\"$S3_ENDPOINT\"}"
send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"us-east-1"}'
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-access-key-input\",\"text\":\"$S3_EMULATOR_ACCESS_KEY\"}"
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-secret-key-input\",\"text\":\"$S3_EMULATOR_SECRET_KEY\"}"
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret added"

#
# Opens the New Database dialog, switches it to S3, picks the secret, and opens the S3 browser on the
# seeded bucket. Leaves the browser open with its listing loading.
#
open_s3_browser() {
    send_command "$APP_PORT" menu '{"itemId":"new-database"}'
    wait_for_log "$TMP_DIR" "Create database dialog opened"

    send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}'
    send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}'

    # The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
    wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
    send_command "$APP_PORT" click '{"dataId":"select-s3-button"}'
    send_command "$APP_PORT" click '{"dataId":"secret-select-button"}'
    wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

    send_command "$APP_PORT" click '{"dataId":"database-browse-button"}'
    # The browser's Cancel button is the readiness gate: the type command below does not wait for its
    # target, so typing into a modal that has not mounted yet would silently go nowhere.
    wait_for_value "$APP_PORT" "s3-browser-cancel" "Cancel"

    # The listing loads on the bucket field changing; there is no separate list button.
    send_command "$APP_PORT" type "{\"dataId\":\"s3-browser-bucket-input\",\"text\":\"$S3_EMULATOR_BUCKET\"}"
}

#
# Waits for a listed directory entry, and on failure reports the browser's own error text before
# failing the test. Without that the only evidence of a failed listing is an empty element.
#
# wait_for_value exits on timeout rather than returning, so it runs in a subshell here: the exit ends
# the subshell and this function sees the non-zero status, instead of the whole test disappearing
# before it can say what went wrong.
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

open_s3_browser

# Each entry renders with a trailing slash ("alpha-dir/"), so match on the name as a prefix. Failing
# here means the listing came back empty or in a different order, both of which are real faults.
expect_listed_dir 0 "alpha-dir"
expect_listed_dir 1 "beta-dir"
log_success "Seeded directories listed from the bucket root"

# Close the browser and the dialog so the next pass starts from a clean form.
send_command "$APP_PORT" click '{"dataId":"s3-browser-cancel"}'
send_command "$APP_PORT" click '{"dataId":"create-database-cancel"}'

# --- 2. A bad credential surfaces an error, not an empty list. ---

# Break the stored credentials through the app's own Edit Secret UI. No navigation is needed: the New
# Database dialog is a modal over whatever page is showing, so cancelling it leaves the secrets page
# on screen. Navigating to the page it is already on changes no route, remounts nothing, and logs
# nothing, so a wait for "Secrets page loaded" here would simply time out.
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-s3-access-key-input","text":"WRONGACCESSKEY"}'
send_command "$APP_PORT" type '{"dataId":"secret-s3-secret-key-input","text":"WRONGSECRETKEY"}'
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

open_s3_browser

# The browser must say the listing failed. An empty list here would render "No sub-directories found
# here." and look exactly like an empty bucket, which is the fault this assertion exists to catch.
if ! ( wait_for_value "$APP_PORT" "s3-browser-error" "Failed to list directories" 60 ); then
    log_error "The S3 browser showed no error for bad credentials (an empty list is not an error)"
    log_error "First listed entry was: $(read_value "$APP_PORT" "s3-browser-dir-0")"
    exit 1
fi
log_success "Bad credentials surfaced an error rather than an empty list"

send_command "$APP_PORT" click '{"dataId":"s3-browser-cancel"}'
send_command "$APP_PORT" click '{"dataId":"create-database-cancel"}'

# The failed listing above is provoked on purpose and is logged by the IPC handler, so it is the one
# error allowed through. Anything else in app.log still fails the test.
check_no_errors "$TMP_DIR" 'Error listing S3 directories'

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 25 passed: s3-database"
