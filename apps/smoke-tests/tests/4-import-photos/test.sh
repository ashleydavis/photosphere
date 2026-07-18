#!/bin/bash

# Imports two fixture images into an empty database and confirms the gallery shows them.
# Electron opens a CLI-created DB and drops host absolute paths onto the import zone.
# Mobile seeds the DB + staged images and uses pick-files with sandbox-relative paths.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 4 "import-photos"

TMP_DIR="$TEST_DIR/tmp"
IMAGES_DIR="$REPO_DIR/test/multiple-files"
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
    STAGE_DIR="$TMP_DIR/import-images"
    mkdir -p "$STAGE_DIR"
    cp "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png" "$STAGE_DIR/"
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
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

if [ "$PLATFORM" = "electron" ]; then
    send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}" || exit 1
else
    send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test-1.jpeg\",\".import-tmp/test-2.png\"]}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
fi

wait_for_log "$TMP_DIR" "2 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"

if [ "$PLATFORM" = "electron" ]; then
    check_no_errors "$TMP_DIR"
else
    check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1
fi

log_success "Test 4 passed: import-photos"
