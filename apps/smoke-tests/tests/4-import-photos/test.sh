#!/bin/bash

# Mobile port of desktop 4-import-photos. Opens a database then imports photos via the import
# drop zone. Fails fast at the unimplemented "menu" (open-database) command on mobile.
#
# Desktop pre-creates a database with the CLI and drops fixture files from the host filesystem;
# the mobile equivalent needs device-side seeding and a device file source once mobile storage
# and import land.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 4 "import-photos"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened" 20
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded" 20

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready" 20

send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$TMP_DIR/test-1.jpeg\",\"$TMP_DIR/test-2.png\"]}" || exit 1
wait_for_log "$TMP_DIR" "2 assets imported" 30

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets" 20

check_no_errors "$TMP_DIR"

log_success "Test 4 passed: import-photos"
