#!/bin/bash

# Mobile port of desktop 6-add-database-entry. Adds a database entry on the Databases page. Desktop
# pre-creates the database with the CLI on the host; on mobile an empty database fixture is copied
# into the app sandbox and the entry's path is the sandbox-relative name. Adding auto-opens the
# database, so the (empty) database must be present to load cleanly.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 6 "add-database-entry"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, then create an empty database (under the test's tmp dir) and copy it into the app
# sandbox for the entry to point at.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/$DB_NAME"
"${PLATFORM}_seed_database" "$TMP_DIR/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added" 20

check_no_errors "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
