#!/bin/bash

# Imports a video, exercising the ffmpeg path (ffprobe for metadata + ffmpeg for the
# screenshot thumbnail). Electron drops the host .mp4 onto the import zone. Mobile seeds
# it into the sandbox import temp dir and uses pick-files.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 21 "import-video"

TMP_DIR="$TEST_DIR/tmp"
VIDEO_SRC="$REPO_DIR/test/multiple-files"
DB_NAME="import-target"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating database with CLI..."
    create_database "$TMP_DIR/test-db"

    log_info "Writing databases.toml with one entry..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
EOF
else
    STAGE_DIR="$TMP_DIR/import-video"
    mkdir -p "$STAGE_DIR"
    cp "$VIDEO_SRC/test.mp4" "$STAGE_DIR/"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    seed_database "$REPO_DIR/test/dbs/no-assets" "$DB_NAME"
    seed_database "$STAGE_DIR" ".import-tmp"
    send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1
fi

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened"
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

if [ "$PLATFORM" = "electron" ]; then
    send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$VIDEO_SRC/test.mp4\"]}" || exit 1
else
    send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test.mp4\"]}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
fi

wait_for_log "$TMP_DIR" "1 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"

if [ "$PLATFORM" = "electron" ]; then
    check_no_errors "$TMP_DIR"
else
    check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1
fi

log_success "Test 21 passed: import-video"
