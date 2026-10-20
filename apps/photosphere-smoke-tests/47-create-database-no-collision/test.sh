#!/bin/bash

# Proves the mobile Browse folder picker yields a distinct sandbox-relative path per database. Two databases are created in a row, each
# with its path filled by Browse (the folder picker's answer is staged with the control connection's pick-answer command, because a
# test cannot type into the native prompt). If both Browse calls returned the same path, the second create would land on the first's
# non-empty directory and fail.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 47 "create-database-no-collision"

trap 'cleanup_apps "$TMP_DIR"' EXIT

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create needs an empty directory at each target path.
"${PLATFORM}_reset_path" "db-one" || exit 1
"${PLATFORM}_reset_path" "db-two" || exit 1

DB_ONE_PATH="$("${PLATFORM}_app_path" "db-one")"
DB_TWO_PATH="$("${PLATFORM}_app_path" "db-two")"

# First database, path chosen via Browse.
click_sidebar_item "$APP_PORT" new-database || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"db-one"}' || exit 1
send_command "$APP_PORT" pick-answer "$(jq -cn --arg path "$DB_ONE_PATH" '{paths: [$path]}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || exit 1
# Browse fills the path field from an async handler, and Create stays disabled while the field is empty, so a Create click sent before
# the path lands is swallowed and nothing happens at all.
wait_for_value "$APP_PORT" "database-path-input" "$DB_ONE_PATH"
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"
# "Database created" is logged just before the dialog is told to close, and a New database sent before that close has rendered asks
# for a dialog that is still open, which does nothing. A user cannot be that quick, so the second request waits for the dialog to go.
wait_for_value_gone "$APP_PORT" "create-database-confirm" "Create" || exit 1

# Second database, a different path chosen via Browse: it must not collide with the first.
click_sidebar_item "$APP_PORT" new-database || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"db-two"}' || exit 1
send_command "$APP_PORT" pick-answer "$(jq -cn --arg path "$DB_TWO_PATH" '{paths: [$path]}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || exit 1
# Here the wait carries the scenario's own assertion too: the field has to read the second path, so a Browse that handed back the first path again
# fails here rather than further downstream.
wait_for_value "$APP_PORT" "database-path-input" "$DB_TWO_PATH"
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"

# A collision would have failed the second create (non-empty directory) and logged an error.
check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 47 passed: create-database-no-collision"
