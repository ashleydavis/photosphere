#!/bin/bash

# Mobile-only test (25+; the 0-24 range mirrors the desktop suite, which has no database-summary
# test). Exercises the get-database-summary handler registered in mobile-worker-entry.ts: opens a
# seeded database, taps the sidebar "Database Info" link (the mobile entry point for
# /database-summary, since mobile has no native menu), and asserts the page loads via the handler
# rather than failing with a handler-registry error. Proven by the page's "Database summary loaded"
# log line, which is only emitted when the handler runs and returns data.
#
# The companion prefetch-database handler is covered by test 36, in its own app instance: this test
# opens the source database, and re-opening the same database in one run cancels its task source,
# after which nothing more can be queued against it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 35 "database-summary"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a source database with one real asset so it has something to summarise.
create_database "$TMP_DIR/source-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/source-db" "source-db"

# Open the source database so a database is current (the sidebar "Database Info" link only shows when
# a database is open) and load-assets runs. The recent name is written with no matching configured
# entry, exactly as before: it resolves to nothing on read, and opening the database is what puts a
# real entry in both lists.
"${PLATFORM}_seed_databases_config" '[]' '["source-db"]' || exit 1
send_command "$APP_PORT" open-database '{"path":"source-db"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed"

# Open the sidebar and tap the Database Info link (the mobile entry point for /database-summary).
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
sleep 1
send_command "$APP_PORT" click '{"dataId":"sidebar-database-summary"}' || exit 1

# The page loads only if the get-database-summary handler ran and returned data; a handler-registry
# error would set the page's error state and never emit this line.
wait_for_log "$TMP_DIR" "Database summary loaded:"

# The page reports the database mode. This database was created by the CLI and holds all its files,
# so full is the only correct answer.
wait_for_value "$APP_PORT" database-mode "full"

# Thumbnail fetches require the not-yet-built mobile asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 35 passed: database-summary"
