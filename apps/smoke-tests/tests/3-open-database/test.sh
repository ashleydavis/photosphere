#!/bin/bash

# Mobile port of desktop 3-open-database. Seeds one configured database (and its files on device),
# opens it from the open-database dialog, and expects the open to complete. Like the desktop test it
# pre-writes databases.toml, except that mobile's copy is in the app's storage sandbox, and the
# database files are copied in there too.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 3 "open-database"

DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the database files and its config-list entry.
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/50-assets" "$DB_NAME"
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]" || exit 1

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened"

# Assert onDatabaseOpened fired from the REAL open flow (the list-item click above drives the real
# openDatabase -> notifyDatabaseOpened path; no TEST_OPEN_DATABASE_EVENT is dispatched). The sidebar
# refreshes its recent-database list only on the database-opened callback, so open the sidebar and
# assert the opened database now appears in the recent list. Without the callback wiring the sidebar
# would not refresh and this element's value would stay empty.
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
wait_for_value "$APP_PORT" "recent-database-name-0" "^$DB_NAME\$"

# Thumbnail fetches require the not-yet-built mobile asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 3 passed: open-database"
