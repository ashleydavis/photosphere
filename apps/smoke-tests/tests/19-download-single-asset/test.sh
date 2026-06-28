#!/bin/bash

# Mobile port of desktop 19-download-single-asset. Opens a database, opens the AssetView, and
# downloads the asset. Fails fast at the unimplemented open-database command on mobile.
#
# Desktop pre-creates the database and asset with the CLI and verifies the saved file on the
# host; the mobile equivalent needs device-side seeding and a device download target.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 19 "download-single-asset"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a database with one asset (test-1.jpeg) under tmp and copy it into the sandbox.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 20
wait_for_log "$TMP_DIR" "Gallery items rendered" 20

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened" 20

send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1
wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg" 20

# Thumbnail/display fetches need the not-yet-built asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset:|Network Error' || exit 1

log_success "Test 19 passed: download-single-asset"
