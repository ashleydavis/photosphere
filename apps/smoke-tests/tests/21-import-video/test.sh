#!/bin/bash

# Imports a video on mobile, exercising the native ffmpeg path (ffprobe for metadata + ffmpeg for the
# screenshot thumbnail) end to end, which the image-only import test (test 4) does not cover. Same
# flow as test 4 but with a single .mp4: seed it into the sandbox import temp dir, stage its path via
# the pick-files command, import it through the photo picker button, and assert it lands in the gallery.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 21 "import-video"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# The empty target database (seeded from the checked-in no-assets fixture) and its sandbox-relative name.
DB_NAME="import-target"

# Stage just the fixture video so only it is seeded.
VIDEO_SRC="$REPO_DIR/test/multiple-files"
STAGE_DIR="$TMP_DIR/import-video"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

mkdir -p "$STAGE_DIR"
cp "$VIDEO_SRC/test.mp4" "$STAGE_DIR/"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Deterministic start, then seed the empty database, the video into the sandbox import temp dir, and
# the database's config-list entry.
send_command "$APP_PORT" reset-config '{}' || exit 1
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/no-assets" "$DB_NAME"
"${PLATFORM}_seed_database" "$STAGE_DIR" ".import-tmp"
send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1

# Open the seeded database.
send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
# "Load assets task completed" is now logged before "Database opened", so waiting for the open first
# would advance the log cursor past the load line and then time out. The load line already proves the
# database opened, so it is the only wait needed.
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

# Go to the import page.
send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

# Stage the picked video path, then click the picker button so the import-assets task runs. The
# upload-asset subtask calls ffprobe (metadata) and ffmpeg (screenshot thumbnail) via FFmpegKit.
send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test.mp4\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "1 assets imported"

# The gallery must now show the imported video asset.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"

# Thumbnail fetches for the freshly imported asset go through the asset-serving layer; ignore only those.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 21 passed: import-video"
