#!/bin/bash

# Mobile port of desktop 2-create-database. Drives the new-database flow from the app menu and
# creates a new empty database in the app's private storage sandbox (the create-database task runs
# in the embedded worker over the native fs write functions). The path is sandbox-relative because
# the native PathSandbox only allows paths under the storage root.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 2 "create-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Remove any existing files at the target path (create requires an empty dir).
"${PLATFORM}_reset_path" "test-db"

send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Database created"

check_no_errors "$TMP_DIR"

log_success "Test 2 passed: create-database"
