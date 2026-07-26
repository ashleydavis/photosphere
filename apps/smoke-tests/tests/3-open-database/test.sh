#!/bin/bash

# Mobile port of desktop 3-open-database. Seeds one configured database (and its files on device),
# opens it from the open-database dialog, and expects the open to complete. The desktop test
# pre-writes databases.toml; on mobile the configured-databases list lives in WebView storage, so it
# is seeded via the test driver, and the database files are copied into the app sandbox.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 3 "open-database"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Deterministic start, then seed the database files and its config-list entry.
send_command "$APP_PORT" reset-config '{}' || exit 1
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/50-assets" "$DB_NAME"
send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1

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
