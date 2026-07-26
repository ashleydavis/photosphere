#!/bin/bash

# Mobile port of desktop 13-edit-s3-credentials. Edits the region of an existing s3-credentials
# secret. Desktop seeds the vault on the host filesystem; on mobile the vault lives on the
# device, so without device-side seeding there is no row to edit.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 13 "edit-s3-credentials"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add one s3-credentials secret through the real Add Secret UI (default type), then edit its region.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

add_secret_via_ui "$APP_PORT" "s3-cred" "s3-credentials" "us-east-1" || exit 1

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"eu-west-1"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

check_no_errors "$TMP_DIR"

log_success "Test 13 passed: edit-s3-credentials"
