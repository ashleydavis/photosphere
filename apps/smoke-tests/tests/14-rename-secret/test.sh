#!/bin/bash

# Mobile port of desktop 14-rename-secret. Renames an existing secret. Desktop seeds the vault
# on the host filesystem; on mobile the vault lives on the device, so without device-side
# seeding there is no row to edit.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 14 "rename-secret"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add one secret through the real Add Secret UI, then rename it (rename works for any type, so the
# default s3-credentials type is used).
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

add_secret_via_ui "$APP_PORT" "old-name" "s3-credentials" "us-east-1" || exit 1

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"new-name"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

check_no_errors "$TMP_DIR"

log_success "Test 14 passed: rename-secret"
