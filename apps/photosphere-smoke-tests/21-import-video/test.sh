#!/bin/bash

# Imports a video on a phone, exercising the bundled ffmpeg path (ffprobe for metadata and ffmpeg for the screenshot thumbnail) end to
# end, which the image-only import scenario does not cover. Same flow as import-photos but with a single .mp4: seed it into the app's
# import temp directory, answer the native picker with its path, import it through the photo picker button, and assert it lands in the
# gallery. The video is never played: the Android emulator pool's software video decoding crashes the emulator itself, so the scenario
# only imports it and reads its metadata.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 21 "import-video"

# The empty target database (seeded from the checked-in no-assets fixture) and its name under the app's files directory.
DB_NAME="import-target"

# Stage just the fixture video so only it is seeded.
VIDEO_SRC="$REPO_DIR/test/multiple-files"
STAGE_DIR="$TMP_DIR/import-video"

trap 'cleanup_apps "$TMP_DIR"' EXIT

mkdir -p "$STAGE_DIR"
cp "$VIDEO_SRC/test.mp4" "$STAGE_DIR/"

# Wipe everything the app has stored on the device (its storage, the web view's data and the keychain) so this scenario starts from a
# known state. Done before launch, with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

# Seed the empty database, the video into the import temp directory, and the database's config-list entry.
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/no-assets" "$DB_NAME" || exit 1
"${PLATFORM}_seed_database" "$STAGE_DIR" ".import-tmp" || exit 1
DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"
IMPORT_TMP_PATH="$("${PLATFORM}_app_path" ".import-tmp")"
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"}]" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"action":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
# "Load assets task completed" is logged before "Database opened", so waiting for the open first would advance the log cursor past the
# load line and then time out. The load line already proves the database opened, so it is the only wait needed.
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

# Answer the picker with the video's path, then click the picker button so the import-assets task runs. The upload-asset subtask calls
# ffprobe (metadata) and ffmpeg (screenshot thumbnail).
send_command "$APP_PORT" pick-answer "{\"paths\":[\"$IMPORT_TMP_PATH/test.mp4\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "1 assets imported"

# The gallery must now show the imported video asset.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"

# Thumbnail fetches for the freshly imported asset go through the asset-serving layer; ignore only those.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 21 passed: import-video"
