#!/bin/bash

# Mobile port of desktop 11-edit-encryption-key. Adds an encryption-key secret through the real Add
# Secret UI, then opens the Edit dialog and re-saves it. The secret is created the way a user would
# (not seeded via a backdoor). The PEM is left empty because the driver cannot type into the PEM
# textarea; this test covers the add-then-edit path for the encryption-key type, not the PEM value.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 11 "edit-encryption-key"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add one encryption-key secret through the real Add Secret UI, then edit it.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

add_secret_via_ui "$APP_PORT" "enc-key" "encryption-key" "" || exit 1

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

check_no_errors "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
