#!/bin/bash

# Adds a database entry on the Databases page. Electron uses a CLI-created host path.
# Mobile seeds an empty DB into the sandbox and uses the sandbox-relative name.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 6 "add-database-entry"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating database with CLI..."
    create_database "$TMP_DIR/test-db"
    DB_PATH="$TMP_DIR/test-db"
else
    DB_PATH="$DB_NAME"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/$DB_NAME"
    seed_database "$TMP_DIR/$DB_NAME" "$DB_NAME"
fi

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

check_no_errors "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
