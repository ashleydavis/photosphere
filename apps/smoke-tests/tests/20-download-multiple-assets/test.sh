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

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a database with two assets under tmp and copy it into the sandbox.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$REPO_DIR/test/multiple-files/test-2.png"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task
# completes in either order, so a sequential wait for one then the other is racy. Wait for the gallery
# to render the items (the signal needed to interact with them); the assets having loaded is verified by
# the download succeeding below.
wait_for_log "$TMP_DIR" "Gallery items rendered"

# Select two assets the phone way. A long press on the first item turns on selecting mode and adds
# it (gallery-image.tsx useLongPress.onLongPress). Selecting mode reveals every item's checkbox
# (display:none until then, with no hover on a phone to reveal it), so the second asset is added by
# clicking its now-visible checkbox.
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}' || exit 1
send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}' || exit 1
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1
wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded"

# Thumbnail fetches need the not-yet-built asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 20 passed: download-multiple-assets"
