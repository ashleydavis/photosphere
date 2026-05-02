#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

source "$TEST_DIR/../lib/common.sh"

print_test_header 2 "create-database"

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

send_command "$APP_PORT" menu '{"itemId":"new-database"}'

wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"

send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}'

wait_for_log "$TMP_DIR" "Database created"

if [ ! -d "$TMP_DIR/test-db/.db" ]; then
    log_error "Expected $TMP_DIR/test-db/.db directory to exist"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 2 passed: create-database"
