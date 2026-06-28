#!/bin/bash

# Mobile port of desktop 18-move-file. Opens a database, selects an asset, and moves it to
# another database. Fails fast at the unimplemented open-database command on mobile.
#
# Desktop pre-creates both databases and an asset with the CLI on the host; the mobile
# equivalent needs device-side seeding once mobile storage lands.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 18 "move-file"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "{\"path\":\"$TMP_DIR/source-db\"}" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 20
wait_for_log "$TMP_DIR" "Gallery items rendered" 20

send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}' || exit 1
wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved" 20

check_no_errors "$TMP_DIR"

log_success "Test 18 passed: move-file"
