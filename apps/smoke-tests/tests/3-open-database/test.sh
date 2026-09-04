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

# The app has to say it is opening, and then say it opened.
#
# Tapping a database queues a probe task and then a load, which on a phone is seconds with nothing on
# screen: the dialog used to close on the tap and leave the user looking at an empty gallery. It now
# stays open, disables every entry and spins on the one tapped until the open resolves.
#
# The pair of log lines is what is asserted rather than the spinner itself, for the same reason test
# 34 asserts the sync spinner through its lifecycle lines: the state clears itself as soon as the open
# finishes, so polling the DOM for it is a race the test would lose whenever the open was quick. These
# two lines are written at the exact points the state is set and cleared.
wait_for_log "$TMP_DIR" "Opening database: $DB_NAME"
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

# --- Restart, and the database the user was in opens again on its own. ---
#
# The app records the open database and opens it again next time it starts. That is meant to work
# the same everywhere, and for a long time it worked only on the desktop: the key was written by the
# Electron main process and read by the shared interface, so on a phone the read found nothing and
# the app started with nothing open, however many times the same database had been opened by hand.
# Nothing failed when it did not work, which is why it went unnoticed, and why this asserts it.
stop_app "$APP_PORT" "$TMP_DIR"

# The relaunched app starts a fresh app.log, so the cursor from the first run points past the end of
# it and every wait below would time out on a line that is there.
rm -f "$TMP_DIR/.log-cursor"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# No command is sent between the app starting and this line. The database opening is the app's own
# doing, which is the whole assertion.
wait_for_log "$TMP_DIR" "Database opened: $DB_NAME" 60 || exit 1
log_success "The database opened by itself after a restart"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 3 passed: open-database"
