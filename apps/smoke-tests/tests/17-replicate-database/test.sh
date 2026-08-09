#!/bin/bash

# Mobile port of desktop 17-replicate-database. Registers a source database and replicates it
# (partial then full). Desktop pre-creates the source database with the CLI and verifies the
# replica files on the host filesystem; on mobile both the source and the replica live on the
# device, so this port drives the UI flow and surfaces where database registration/replication
# is missing. Host-side file assertions are dropped (they cannot see device storage).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "replicate-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create an empty source database (under tmp) and copy it into the sandbox
# (adding it auto-opens it). Also clear any replica from a previous run so the destination starts
# empty (replicating onto an unrelated existing database is refused without --force).
"${PLATFORM}_reset_path" "dest-partial"
create_database "$TMP_DIR/source-db"
"${PLATFORM}_seed_database" "$TMP_DIR/source-db" "source-db"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"source-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

# Waited for here, before the navigation below, and not after it. Confirming the dialog registers the
# entry and then opens that database, which emits "Database opened" and then a second "Databases page
# loaded" render. Waiting on the render first consumed that pair from the wrong end: wait_for_log
# carries a cursor, so matching the open's render moved the cursor past the "Database opened" that
# preceded it, and the later wait for it then had nothing left to find and timed out. That is what
# failed this test on the iOS runner, where the whole open completed before the test navigated at all.
#
# The navigation cannot be relied on to produce a render of its own either: the auto-open leaves the
# app on the databases page already, and navigating to the route it is on emits nothing.
wait_for_log "$TMP_DIR" "Database opened"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1

# The open re-renders the card list, so it has to settle before the menu is opened: otherwise it
# lands mid-test and tears the menu down before the action can be clicked. The navbar marker is
# rendered only while a database is open, and the render after it is what actually replaces the list.
wait_for_value "$APP_PORT" database-photo-count "photos"
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"

# --- Replicate a second time. ---
#
# A replication tags its task queue with the source database's path and shuts that queue down when it
# finishes, which cancels the source. The engine pool used to remember a cancelled source for the life
# of the app, so this second replication was discarded before it ran: no error, no log line, the
# dialog simply sat there. Anything that queues work under the same source twice hit the same wall,
# which is why this assertion exists rather than a unique tag hiding it.
send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-second"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"
log_success "A second replication of the same database ran, rather than being silently dropped"

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: replicate-database"
