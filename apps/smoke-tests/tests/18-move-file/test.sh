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

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a source database with one asset and an empty destination database (under tmp), copy both
# into the sandbox, and register both so the right sidebar offers "dest-db" as a move target.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/source-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
create_database "$TMP_DIR/dest-db"
"${PLATFORM}_seed_database" "$TMP_DIR/source-db" "source-db"
"${PLATFORM}_seed_database" "$TMP_DIR/dest-db" "dest-db"
send_command "$APP_PORT" seed-databases '{"databases":[{"name":"source-db","path":"source-db"},{"name":"dest-db","path":"dest-db"}]}' || exit 1

send_command "$APP_PORT" open-database '{"path":"source-db"}' || exit 1
# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task
# completes in either order, so a sequential wait for one then the other is racy. Wait for the gallery
# to render the item (the signal needed to select it below).
wait_for_log "$TMP_DIR" "Gallery items rendered"

# Select the asset the way a phone user does: a long press on the gallery item, which turns on
# selecting mode and adds the item to the selection (gallery-image.tsx useLongPress.onLongPress).
# The selection checkbox is display:none on a phone until then (no hover to reveal it), so clicking
# it directly cannot work; a real long press is the gesture that selects.
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}' || exit 1
wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved"

# Thumbnail fetches need the not-yet-built asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 18 passed: move-file"
