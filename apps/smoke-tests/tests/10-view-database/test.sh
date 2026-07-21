#!/bin/bash

# Mobile port of desktop 10-view-database. Adds a database entry with a geocoding secret, then
# views the database and reveals the secret. Exercises the databases + secret-selection flow.
#
# Desktop pre-creates the database and api-key secret with the CLI on the host; the mobile
# equivalent needs device-side seeding once mobile storage lands.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 10 "view-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, place an empty database in the sandbox (add auto-opens it), and add an api-key secret
# through the real Add Secret UI to attach as the geocoding key.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_secret_via_ui "$APP_PORT" "geo-key" "api-key" "the-geocoding-key" || exit 1

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"select-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "Select secret modal ready"

send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Confirming the Add Database dialog registers the entry and then opens that database, which
# re-renders the card list. That open runs after "Database entry added" is logged, so wait for it to
# settle before opening the menu: otherwise it lands mid-test and tears the menu down before the
# action can be clicked. Polled from the navbar marker (rendered only while a database is open)
# rather than a log line, because the open can complete either side of the page-loaded event and a
# log wait would miss an early one.
wait_for_value "$APP_PORT" database-photo-count "photos"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"view-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "View database dialog opened"

send_command "$APP_PORT" click '{"dataId":"view-secret-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed"

check_no_errors "$TMP_DIR"

log_success "Test 10 passed: view-database"
