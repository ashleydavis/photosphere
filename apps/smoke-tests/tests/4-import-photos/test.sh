#!/bin/bash

# Mobile port of desktop 4-import-photos. Seeds an empty database and two fixture images into the app
# sandbox, opens the database, and imports the two images through the native photo picker path (the
# mobile replacement for drag-and-drop). Exercises the full mobile import pipeline: the import-assets
# orchestrator task spawns hash-file / upload-asset subtasks that round-trip through the native engine
# pool (queued back on the main-thread queue, run on other engine slots, completions delivered back),
# and the images are processed with the bundled native ImageMagick/ffmpeg.
#
# Drag-and-drop does not exist on a phone, so the drop zone is hidden and a "Select photos" button
# opens the native picker. The picker cannot be automated, so its result is injected: the fixture
# images are copied into the sandbox .import-tmp directory and their sandbox-relative paths are staged
# with the pick-files command; clicking import-files-button then imports exactly those paths.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 4 "import-photos"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# The empty target database (seeded from the checked-in no-assets fixture) and its sandbox-relative name.
DB_NAME="import-target"

# Stage the two fixture images so only they (not the large archive/video siblings) are seeded.
IMAGES_DIR="$REPO_DIR/test/multiple-files"
STAGE_DIR="$TMP_DIR/import-images"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

mkdir -p "$STAGE_DIR"
cp "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png" "$STAGE_DIR/"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Deterministic start, then seed the empty database, the two images into the sandbox import temp
# directory, and the database's config-list entry.
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

# Stage the picked paths, then click the picker button so pickFiles resolves with them and the
# import-assets task runs (spawning hash-file / upload-asset subtasks through the engine pool).
send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test-1.jpeg\",\".import-tmp/test-2.png\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "2 assets imported"

# The gallery must now show the two imported assets.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"

# Thumbnail fetches for freshly imported assets go through the asset-serving layer; ignore only those.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 4 passed: import-photos"
