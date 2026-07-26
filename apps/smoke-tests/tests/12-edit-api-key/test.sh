#!/bin/bash

# Mobile port of desktop 12-edit-api-key. Adds an api-key secret through the real Add Secret UI, then
# edits it. The precondition secret is created the same way a user would (not seeded via a backdoor),
# so the test covers the whole add-then-edit path end to end.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 12 "edit-api-key"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add one api-key secret through the real Add Secret UI, then edit it.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

add_secret_via_ui "$APP_PORT" "api-key" "api-key" "the-api-key-value" || exit 1

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

check_no_errors "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
