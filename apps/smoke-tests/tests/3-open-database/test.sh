#!/bin/bash

# Mobile port of desktop 3-open-database. Drives the open-database flow from the app menu.
# The "menu" command is not implemented on mobile, so the test fails fast there.
#
# Desktop pre-creates a database with the CLI and seeds databases.toml on the host; the mobile
# equivalent needs device-side seeding once mobile storage lands.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 3 "open-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened" 20

check_no_errors "$TMP_DIR"

log_success "Test 3 passed: open-database"
