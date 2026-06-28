#!/bin/bash

# Mobile port of desktop 12-edit-api-key. Edits an existing api-key secret. Desktop seeds the
# vault on the host filesystem; on mobile the vault lives on the device, so without device-side
# seeding there is no row to edit and the flow stops at the missing Edit dialog.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 12 "edit-api-key"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded" 20

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated" 20

check_no_errors "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
