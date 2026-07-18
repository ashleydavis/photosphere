#!/bin/bash

# Opens a database, selects two assets, and downloads them.
# Electron bypasses the folder picker via PHOTOSPHERE_TEST_DOWNLOAD_FOLDER and asserts
# both files match the originals. Mobile uses long-press + checkbox selection.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 20 "download-multiple-assets"

TMP_DIR="$TEST_DIR/tmp"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    SOURCE_DB="$TMP_DIR/test-db"
    DOWNLOAD_DIR="$TMP_DIR/downloads"

    log_info "Pre-creating database and importing two fixtures..."
    create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png"

    log_info "Writing databases.toml..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
EOF

    mkdir -p "$DOWNLOAD_DIR"
    export PHOTOSPHERE_TEST_DOWNLOAD_FOLDER="$DOWNLOAD_DIR"

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    log_info "Opening database..."
    send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded"
    log_success "Database opened with 2 assets"

    wait_for_log "$TMP_DIR" "Gallery items rendered"
    log_success "Gallery items are in the DOM"

    # Long-press selects the first asset and enters selection mode so checkboxes
    # become visible for the second asset (they are display:none until then).
    log_info "Selecting both gallery items..."
    send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}' || exit 1

    log_info "Opening right sidebar..."
    send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1

    log_info "Clicking Download N assets..."
    send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1

    wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded"
    log_success "Download to folder completed"

    log_info "Verifying both downloaded files exist on disk..."
    for filename in test-1.jpeg test-2.png; do
        if [ ! -f "$DOWNLOAD_DIR/$filename" ]; then
            log_error "Expected downloaded file not found: $DOWNLOAD_DIR/$filename"
            log_error "Contents of $DOWNLOAD_DIR:"
            ls -la "$DOWNLOAD_DIR" || true
            exit 1
        fi
    done
    log_success "Both downloaded files exist in $DOWNLOAD_DIR"

    log_info "Verifying downloaded files match the originals byte-for-byte..."
    for filename in test-1.jpeg test-2.png; do
        if ! cmp -s "$IMAGES_DIR/$filename" "$DOWNLOAD_DIR/$filename"; then
            log_error "Downloaded file content does not match the original."
            log_error "  Original: $IMAGES_DIR/$filename"
            log_error "  Downloaded: $DOWNLOAD_DIR/$filename"
            exit 1
        fi
    done
    log_success "Both downloaded files match the originals"

    check_no_errors "$TMP_DIR"

    log_success "Test 20 passed: download-multiple-assets"
else
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$REPO_DIR/test/multiple-files/test-2.png"
    seed_database "$TMP_DIR/test-db" "test-db"

    send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
    wait_for_log "$TMP_DIR" "Gallery items rendered"

    send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded"

    check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

    log_success "Test 20 passed: download-multiple-assets"
fi
