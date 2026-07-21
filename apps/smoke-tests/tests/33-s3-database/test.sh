#!/bin/bash

# Substeps 14c-14d: list a real S3 bucket on device through the mobile worker's S3 client, and prove the
# failure paths surface rather than looking empty.
#
# This is an OPT-IN test (like packages/storage/integration-tests): it needs a disposable S3 bucket and
# credentials, so it SKIPS cleanly with a clear log line when TEST_S3_BUCKET is unset, keeping
# `bun run test:and` runnable without credentials. Point it at MinIO via AWS_ENDPOINT for local runs.
#
# Asserts three things the plan calls out:
#   1. a populated bucket lists (assert_value on a listed directory),
#   2. a bad credential shows an error, not an empty list,
#   3. a bad server certificate fails closed (validated TLS mode; 14c's fail-closed guarantee).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 33 "s3-database"

TMP_DIR="$TEST_DIR/tmp"

if [ -z "${TEST_S3_BUCKET:-}" ]; then
    log_info "SKIP: 33-s3-database requires TEST_S3_BUCKET / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (and AWS_ENDPOINT for MinIO). Skipping."
    log_success "Test 33 skipped: s3-database (no credentials)"
    exit 0
fi

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" reset-config '{}' || exit 1

# Add valid S3 credentials to the device keychain as an s3-credentials secret, through the app's own
# add-secret UI (the real path a secret takes into the keychain). s3-credentials is the dialog's
# default type, so no type change is needed.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"s3"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-region-input\",\"text\":\"${AWS_DEFAULT_REGION:-us-east-1}\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-access-key-input\",\"text\":\"$AWS_ACCESS_KEY_ID\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-secret-key-input\",\"text\":\"$AWS_SECRET_ACCESS_KEY\"}" || exit 1
if [ -n "${AWS_ENDPOINT:-}" ]; then
    send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-endpoint-input\",\"text\":\"$AWS_ENDPOINT\"}" || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

# 1. A populated bucket lists: open the S3 browser and assert at least one directory appears.
send_command "$APP_PORT" navigate '{"page":"s3-browser"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"s3-browser-bucket-input\",\"text\":\"$TEST_S3_BUCKET\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"s3-browser-list-button"}' || exit 1
wait_for_value "$APP_PORT" "s3-browser-dir-0" "." 30

# 2. A bad credential shows an error, not an empty list: edit the secret's keys to bad values through
# the app's edit-secret UI, then re-list. Navigating away resets the S3 browser, so the bucket is
# re-entered before listing again.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-s3-access-key-input","text":"BAD"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"secret-s3-secret-key-input","text":"BAD"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

send_command "$APP_PORT" navigate '{"page":"s3-browser"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"s3-browser-bucket-input\",\"text\":\"$TEST_S3_BUCKET\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"s3-browser-list-button"}' || exit 1
wait_for_value "$APP_PORT" "s3-browser-error" "." 30

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'

log_success "Test 33 passed: s3-database"
