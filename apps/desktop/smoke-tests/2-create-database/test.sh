#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 2 "create-database"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
}
trap cleanup EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"new-database"}'

wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}'

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
