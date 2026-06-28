#!/bin/bash

# Mobile port of desktop 2-create-database. Drives the new-database flow from the app menu.
# On mobile the "menu" command is not implemented (no native menu), so the test fails fast at
# that command, pinpointing the gap.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 2 "create-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Database created" 20

check_no_errors "$TMP_DIR"

log_success "Test 2 passed: create-database"
