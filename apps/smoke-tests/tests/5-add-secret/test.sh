#!/bin/bash

# Mobile port of desktop 5-add-secret. Navigates to the Secrets page and adds a secret. Uses
# only navigate/click/type, so it exercises how far the secrets flow gets on mobile before the
# vault write (platform provider) is missing.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 5 "add-secret"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate so the secret name is not seen as a duplicate from a previous run.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

check_no_errors "$TMP_DIR"

log_success "Test 5 passed: add-secret"
