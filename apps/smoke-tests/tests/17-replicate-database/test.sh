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

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Confirming the Add Database dialog registers the entry and then opens that database, which
# re-renders the card list. That open runs after "Database entry added" is logged, so wait for it to
# settle before opening the menu: otherwise it lands mid-test and tears the menu down before the
# action can be clicked. Polled from the navbar marker (rendered only while a database is open)
# rather than a log line, because the open can complete either side of the page-loaded event and a
# log wait would miss an early one. The navbar marker is no longer enough on its own: the open now
# emits a second "Databases page loaded" render after "Database opened", which lands after the marker
# appears and tears the menu down, so wait for that render too.
wait_for_value "$APP_PORT" database-photo-count "photos"
wait_for_log "$TMP_DIR" "Database opened"
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: replicate-database"
