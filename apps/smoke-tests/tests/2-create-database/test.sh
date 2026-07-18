#!/bin/bash

# Drives the new-database flow from the app menu and creates an empty database.
# Electron uses an absolute host path under tmp and asserts .db exists on disk.
# Mobile uses a sandbox-relative path after reset-config / reset_path.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 2 "create-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" = "electron" ]; then
    DB_PATH="$TMP_DIR/test-db"
else
    send_command "$APP_PORT" reset-config '{}' || exit 1
    reset_path "test-db"
    DB_PATH="test-db"
fi

send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Database created"

if [ "$PLATFORM" = "electron" ]; then
    if [ ! -d "$TMP_DIR/test-db/.db" ]; then
        log_error "Expected $TMP_DIR/test-db/.db directory to exist"
        exit 1
    fi
fi

check_no_errors "$TMP_DIR"

log_success "Test 2 passed: create-database"
