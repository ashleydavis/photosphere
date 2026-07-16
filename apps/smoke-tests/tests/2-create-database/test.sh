#!/bin/bash

# Mobile port of desktop 2-create-database. Drives the new-database flow from the app menu and
# creates a new empty database in the app's private storage sandbox (the create-database task runs
# in the embedded worker over the native fs write functions). The path is sandbox-relative because
# the native PathSandbox only allows paths under the storage root.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 2 "create-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Start from a clean state: clear the persisted config (so the name is not seen as a duplicate from
# a previous test) and remove any existing files at the target path (create requires an empty dir).
send_command "$APP_PORT" reset-config '{}' || exit 1
"${PLATFORM}_reset_path" "test-db"

send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Database created"

check_no_errors "$TMP_DIR"

log_success "Test 2 passed: create-database"
