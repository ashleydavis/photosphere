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

# Clean slate, place an empty database in the sandbox (add auto-opens it), and seed an api-key
# secret to attach as the geocoding key.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"
send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"geo-key","type":"api-key"},"value":"the-geocoding-key"}]}' || exit 1

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"select-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "Select secret modal ready" 20

send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added" 20

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"view-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "View database dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"view-secret-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed" 20

check_no_errors "$TMP_DIR"

log_success "Test 10 passed: view-database"
