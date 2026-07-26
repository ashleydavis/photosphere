#!/bin/bash

# Mobile port of desktop 19-download-single-asset. Opens a database, opens the AssetView, and
# downloads the asset. Fails fast at the unimplemented open-database command on mobile.
#
# Desktop pre-creates the database and asset with the CLI and verifies the saved file on the
# host; the mobile equivalent needs device-side seeding and a device download target.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 19 "download-single-asset"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a database with one asset (test-1.jpeg) under tmp and copy it into the sandbox.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task
# completes in either order, so a sequential wait for one then the other is racy. Wait for the gallery
# to render the item (the signal needed to click the thumbnail); the asset having loaded is verified by
# the download succeeding below.
wait_for_log "$TMP_DIR" "Gallery items rendered"

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

# The download hands the saved file out via the native share/save sheet, which an automated test
# cannot dismiss. Stage the sheet outcome so the export completes in test mode instead of blocking.
send_command "$APP_PORT" stage-export '{"exportOutcome":"shared"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1
wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg"

# Thumbnail/display fetches need the not-yet-built asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset:|Network Error' || exit 1

log_success "Test 19 passed: download-single-asset"
