#!/bin/bash

# Mobile port of desktop 16-remove-recent-database. Opens the sidebar and removes a recent
# database. Desktop seeds two databases and databases.toml on the host; on mobile the recent
# list lives on the device, so the precondition needs device-side seeding.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 16 "remove-recent-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
sleep 1

send_command "$APP_PORT" click '{"dataId":"remove-recent-database-button-0"}' || exit 1
wait_for_log "$TMP_DIR" "Recent database removed" 20

check_no_errors "$TMP_DIR"

log_success "Test 16 passed: remove-recent-database"
