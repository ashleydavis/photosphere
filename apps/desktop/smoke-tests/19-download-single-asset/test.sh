#!/bin/bash

# Smoke test: download a single asset from the AssetView.
#
# Flow:
#   1. Pre-create a database and import one fixture via the CLI.
#   2. Start the Electron app and open the database.
#   3. Open the AssetView for the imported asset by long-press-clicking the
#      first gallery thumb (a real .click() is not enough — the thumb uses
#      useLongPress which only reacts to mousedown/mouseup).
#   4. Click the Download icon inside the AssetView.
#   5. Wait for the log line emitted when the save-asset task completes.
#   6. Confirm the saved file exists on disk in the test download folder.
#
# The save-file picker is bypassed in test mode by PHOTOSPHERE_TEST_PICK_FILE_PATH;
# the env var supplies the destination path that the renderer would otherwise
# choose via dialog.showSaveDialog.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-images"

print_test_header 19 "download-single-asset"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)
SOURCE_DB="$TMP_DIR/test-db"
DOWNLOAD_DIR="$TMP_DIR/downloads"
DOWNLOAD_FILE="$DOWNLOAD_DIR/test-1.jpeg"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

log_info "Pre-creating database and importing a fixture..."
cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes
cd "$DESKTOP_DIR"

log_info "Writing databases.toml..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
EOF

mkdir -p "$DOWNLOAD_DIR"

# Tell the renderer's pickFile bridge to skip the native save dialog
# and use this path directly for the next save-asset call.
export PHOTOSPHERE_TEST_PICK_FILE_PATH="$DOWNLOAD_FILE"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Opening database..."
send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 60
log_success "Database opened with 1 asset"

wait_for_log "$TMP_DIR" "Gallery items rendered" 30
log_success "Gallery items are in the DOM"

log_info "Opening AssetView via long-press click on the first gallery thumb..."
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}'
wait_for_log "$TMP_DIR" "AssetView opened" 15
log_success "AssetView is open"

log_info "Clicking the Download icon in AssetView..."
send_command "$APP_PORT" click '{"dataId":"download-asset-button"}'

wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg" 30
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
