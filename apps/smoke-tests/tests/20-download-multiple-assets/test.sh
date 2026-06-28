#!/bin/bash

# Mobile port of desktop 20-download-multiple-assets. Opens a database, selects two assets, and
# downloads them. Fails fast at the unimplemented open-database command on mobile.
#
# Desktop pre-creates the database and two assets with the CLI and verifies the saved files on
# the host; the mobile equivalent needs device-side seeding and a device download target.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 20 "download-multiple-assets"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "{\"path\":\"$TMP_DIR/test-db\"}" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded" 20
wait_for_log "$TMP_DIR" "Gallery items rendered" 20

send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":0}' || exit 1
send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}' || exit 1
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1
wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded" 20

check_no_errors "$TMP_DIR"

log_success "Test 20 passed: download-multiple-assets"
