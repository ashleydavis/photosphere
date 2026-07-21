#!/bin/bash

# Proves the mobile "Browse" folder picker (substep 12a) yields a distinct sandbox-relative path per
# database rather than the fixed "downloads" the old stub returned. Two databases are created in a
# row, each with its path filled by Browse (the path is staged via stage-pick-folder because the
# native name prompt cannot be typed by an automated test). Before this fix both Browse calls returned
# "downloads", so the second create landed on the first's non-empty directory and failed; now the two
# paths differ and both creates succeed with no error.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 31 "create-database-no-collision"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Start clean: clear config and remove any files at the two target paths (create needs an empty dir).
send_command "$APP_PORT" reset-config '{}' || exit 1
"${PLATFORM}_reset_path" "db-one"
"${PLATFORM}_reset_path" "db-two"

# --- First database, path chosen via Browse. ---
send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"db-one"}' || exit 1
send_command "$APP_PORT" stage-pick-folder '{"folderResult":"db-one"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"

# --- Second database, a different path chosen via Browse: it must not collide with the first. ---
send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"db-two"}' || exit 1
send_command "$APP_PORT" stage-pick-folder '{"folderResult":"db-two"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"

# A collision would have failed the second create (non-empty directory) and logged an error.
check_no_errors "$TMP_DIR"

log_success "Test 31 passed: create-database-no-collision"
