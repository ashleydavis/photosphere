#!/bin/bash

# Mobile port of desktop 6-add-database-entry. Adds a database entry on the Databases page. Desktop
# pre-creates the database with the CLI on the host; on mobile an empty database fixture is copied
# into the app sandbox and the entry's path is the sandbox-relative name. Adding auto-opens the
# database, so the (empty) database must be present to load cleanly.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 6 "add-database-entry"

DB_NAME="test-db"

# The name the entry is given in the database list. It carries no spaces because the assertion below
# reads the row back through the control bridge, which puts the data-id straight into a URL query.
ENTRY_NAME="my-test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create an empty database (under the test's tmp dir) and copy it into the app
# sandbox for the entry to point at.
create_database "$TMP_DIR/$DB_NAME"
"${PLATFORM}_seed_database" "$TMP_DIR/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$ENTRY_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

# The log line alone proved nothing: the provider writes it straight after awaiting
# configStore.addDatabase, so an entry that never reaches databases.toml leaves it intact and this
# test passed with nothing registered. Confirmed by dropping the addDatabase call and watching this
# test still pass. The databases page renders one row per configured entry, so waiting for the row
# to carry the entry's name is the assertion that it was really added and read back.
send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_value "$APP_PORT" "database-row-name-$ENTRY_NAME" "$ENTRY_NAME"

check_no_errors "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
