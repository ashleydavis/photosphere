#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 5 "add-secret"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'

wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'

wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}'

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'

wait_for_log "$TMP_DIR" "Secret added"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 5 passed: add-secret"
