#!/bin/bash

# Adds a secret then views and reveals it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 9 "view-secret"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"smoke-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"view-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed"

check_no_errors "$TMP_DIR"

log_success "Test 9 passed: view-secret"
