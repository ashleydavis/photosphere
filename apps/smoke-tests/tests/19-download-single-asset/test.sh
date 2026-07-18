#!/bin/bash

# Opens a database, opens the AssetView, and downloads the asset.
# Electron bypasses the save dialog via PHOTOSPHERE_TEST_PICK_FILE_PATH and asserts
# the downloaded file matches the original byte-for-byte. Mobile drives the UI flow only.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 19 "download-single-asset"

TMP_DIR="$TEST_DIR/tmp"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    SOURCE_DB="$TMP_DIR/test-db"
    DOWNLOAD_DIR="$TMP_DIR/downloads"
    DOWNLOAD_FILE="$DOWNLOAD_DIR/test-1.jpeg"

    log_info "Pre-creating database and importing a fixture..."
    create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"

    log_info "Writing databases.toml..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
EOF

    mkdir -p "$DOWNLOAD_DIR"
    export PHOTOSPHERE_TEST_PICK_FILE_PATH="$DOWNLOAD_FILE"

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    log_info "Opening database..."
    send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
    log_success "Database opened with 1 asset"

    wait_for_log "$TMP_DIR" "Gallery items rendered"
    log_success "Gallery items are in the DOM"

    log_info "Opening AssetView via long-press click on the first gallery thumb..."
    send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
    wait_for_log "$TMP_DIR" "AssetView opened"
    log_success "AssetView is open"

    log_info "Clicking the Download icon in AssetView..."
    send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1

    wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg"
    log_success "Download completed event logged"

    log_info "Verifying downloaded file exists on disk..."
    if [ ! -f "$DOWNLOAD_FILE" ]; then
        log_error "Expected downloaded file not found: $DOWNLOAD_FILE"
        log_error "Contents of $DOWNLOAD_DIR:"
        ls -la "$DOWNLOAD_DIR" || true
        exit 1
    fi
    log_success "Downloaded file exists at $DOWNLOAD_FILE"

    log_info "Verifying downloaded file matches the original byte-for-byte..."
    if ! cmp -s "$IMAGES_DIR/test-1.jpeg" "$DOWNLOAD_FILE"; then
        log_error "Downloaded file content does not match the original."
        log_error "  Original: $IMAGES_DIR/test-1.jpeg"
        log_error "  Downloaded: $DOWNLOAD_FILE"
        exit 1
    fi
    log_success "Downloaded file content matches the original"

    check_no_errors "$TMP_DIR"

    log_success "Test 19 passed: download-single-asset"
else
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
    seed_database "$TMP_DIR/test-db" "test-db"

    send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
    wait_for_log "$TMP_DIR" "Gallery items rendered"

    send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
    wait_for_log "$TMP_DIR" "AssetView opened"

    send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg"

    check_no_errors "$TMP_DIR" 'Failed to load asset:|Network Error' || exit 1

    log_success "Test 19 passed: download-single-asset"
fi
