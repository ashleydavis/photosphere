#!/bin/bash

# Mobile counterpart of desktop 25-s3-database. Browses an S3 bucket from the Add Database dialog,
# against a real S3 server.
#
# This asserts the S3 BROWSER LISTING, which is the behaviour being covered: the same two things the
# desktop test asserts, driven through the same shared component.
#
#   1. A populated bucket lists its seeded directories by name. This covers listing the *top* of a
#      bucket (an empty key), which the storage layer used to reject before the request was sent.
#   2. A bad credential surfaces an error in the browser rather than an empty list. An empty list is
#      the failure this test exists to catch: it looks exactly like an empty bucket.
#
# On mobile each listing runs as a `list-s3-dirs` background task on the embedded worker, so this
# also exercises the real AWS SDK inside the embedded JS engine over plain HTTP. The second browse
# reuses the `list-s3-dirs` task source after the first browser closed and cancelled it, so it also
# covers the engine pool reviving a cancelled source when the WebView queues new work.
#
# The server runs on the host, so the endpoint uses the address the device reaches the host at
# (192.168.55.1 on a bridged emulator, 10.0.2.2 under NAT, loopback on the iOS simulator), never
# "localhost", which on a device means the device itself.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 40 "s3-database"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running. The
# emulator's stop is safe to call when nothing was started, so it goes in unconditionally.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; (cd "$REPO_DIR" && bun run s3-emulator stop "$S3_STATE_DIR") >/dev/null 2>&1 || true' EXIT

mkdir -p "$TMP_DIR"

# Start the S3 server and read back the port it bound, the bucket it seeded and its credentials.
if ! (cd "$REPO_DIR" && bun run s3-emulator start "$S3_STATE_DIR"); then
    log_error "Could not start the local S3 emulator"
    exit 1
fi
# shellcheck disable=SC1090
source "$S3_STATE_DIR/env"
S3_HOST="$("${PLATFORM}_host_address")"
S3_ENDPOINT="http://$S3_HOST:$S3_EMULATOR_PORT"
log_info "S3 emulator reachable from the device at $S3_ENDPOINT, bucket $S3_EMULATOR_BUCKET"

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add the S3 credentials through the app's own Add Secret UI, the way a user would. The dialog is
# driven field by field rather than through add_secret_via_ui, which only fills the region.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" type "{\"dataId\":\"secret-name-input\",\"text\":\"$SECRET_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-endpoint-input\",\"text\":\"$S3_ENDPOINT\"}" || exit 1
send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"us-east-1"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-access-key-input\",\"text\":\"$S3_EMULATOR_ACCESS_KEY\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-secret-key-input\",\"text\":\"$S3_EMULATOR_SECRET_KEY\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

#
# Opens the Add Database dialog, switches it to S3, picks the secret, and opens the S3 browser on the
# seeded bucket. Leaves the browser open with its listing loading.
#
open_s3_browser() {
    send_command "$APP_PORT" navigate '{"page":"databases"}' || return 1
    wait_for_log "$TMP_DIR" "Databases page loaded"
    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || return 1
    send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || return 1
    wait_for_log "$TMP_DIR" "Add database dialog opened"

    send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}' || return 1
    send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}' || return 1

    # The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
    wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
    send_command "$APP_PORT" click '{"dataId":"select-s3-button"}' || return 1
    send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || return 1
    wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

    send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || return 1
    # The browser's Cancel button is the readiness gate: the type command below does not wait for its
    # target, so typing into a sheet that has not opened yet would silently go nowhere.
    wait_for_value "$APP_PORT" "s3-browser-cancel" "Cancel"

    # The listing loads on the bucket field changing; there is no separate list button.
    send_command "$APP_PORT" type "{\"dataId\":\"s3-browser-bucket-input\",\"text\":\"$S3_EMULATOR_BUCKET\"}" || return 1
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

open_s3_browser || exit 1

# Each entry renders with a trailing slash ("alpha-dir/"), so match on the name as a prefix. Failing
# here means the listing came back empty or in a different order, both of which are real faults.
expect_listed_dir 0 "alpha-dir"
expect_listed_dir 1 "beta-dir"
log_success "Seeded directories listed from the bucket root"

# Close the browser and the dialog so the next pass starts from a clean form. Closing the browser
# shuts its TaskQueue down, which cancels the list-s3-dirs source; the second browse below only
# works because the engine pool revives that source when the WebView queues the next task.
send_command "$APP_PORT" click '{"dataId":"s3-browser-cancel"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-cancel"}' || exit 1

# --- 2. A bad credential surfaces an error, not an empty list. ---

# Break the stored credentials through the app's own Edit Secret UI.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-s3-access-key-input","text":"WRONGACCESSKEY"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"secret-s3-secret-key-input","text":"WRONGSECRETKEY"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

open_s3_browser || exit 1

# The browser must say the listing failed. An empty list here would render "No sub-directories found
# here." and look exactly like an empty bucket, which is the fault this assertion exists to catch.
if ! ( wait_for_value "$APP_PORT" "s3-browser-error" "Failed to list directories" 60 ); then
    log_error "The S3 browser showed no error for bad credentials (an empty list is not an error)"
    log_error "First listed entry was: $(read_value "$APP_PORT" "s3-browser-dir-0")"
    exit 1
fi
log_success "Bad credentials surfaced an error rather than an empty list"

send_command "$APP_PORT" click '{"dataId":"s3-browser-cancel"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-cancel"}' || exit 1

# The failed listing above is provoked on purpose and is logged by the worker task, so it is the one
# error allowed through. Anything else in app.log still fails the test.
check_no_errors "$TMP_DIR" 'Failed to list directories|list-s3-dirs'

log_success "Test 40 passed: s3-database"
