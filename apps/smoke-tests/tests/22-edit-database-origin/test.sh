#!/bin/bash

# Mobile port of desktop 22-edit-database-origin. Adds a database entry, edits its origin, and
# saves. Desktop pre-creates the database with the CLI and verifies .db/config.json on the host;
# on mobile the database lives on the device, so host-side file assertions are dropped and the
# port drives the UI flow to surface where database entry editing is missing.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 22 "edit-database-origin"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)
NEW_ORIGIN="s3:my-bucket:/origin-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, then create an empty database (under tmp) and copy it into the app sandbox (adding a
# database auto-opens it).
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened" 20
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added" 20

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20
send_command "$APP_PORT" click '{"dataId":"edit-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit database dialog opened" 20

send_command "$APP_PORT" type "{\"dataId\":\"database-origin-input\",\"text\":\"$NEW_ORIGIN\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"save-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry updated" 20

check_no_errors "$TMP_DIR"

log_success "Test 22 passed: edit-database-origin"
