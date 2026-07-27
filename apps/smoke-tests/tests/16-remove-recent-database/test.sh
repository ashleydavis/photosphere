#!/bin/bash

# Mobile port of desktop 16-remove-recent-database. Opens the sidebar and removes a recent
# database. Desktop seeds two databases and databases.toml on the host; on mobile the recent
# list lives on the device, so the precondition needs device-side seeding.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 16 "remove-recent-database"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed one recent database (desktop seeds databases.toml). Place its (empty) files in the sandbox and
# open it so the sidebar re-reads the recent list (it refreshes on the database-opened event).
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"
# Recents are stored as names and resolved against the configured-databases list, so a recent with no
# matching configured entry is dropped on read and never renders. Seed the entry as well as the recent.
send_command "$APP_PORT" seed-databases '{"databases":[{"name":"test-db","path":"test-db"}]}' || exit 1
send_command "$APP_PORT" seed-recent '{"recent":[{"name":"test-db","path":"test-db"}]}' || exit 1
send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
sleep 1

send_command "$APP_PORT" click '{"dataId":"remove-recent-database-button-0"}' || exit 1
wait_for_log "$TMP_DIR" "Recent database removed"

check_no_errors "$TMP_DIR"

log_success "Test 16 passed: remove-recent-database"
