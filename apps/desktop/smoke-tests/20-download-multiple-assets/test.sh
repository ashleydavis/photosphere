#!/bin/bash

# Smoke test: download multiple selected assets from the right sidebar.
#
# Flow:
#   1. Pre-create a database and import two fixtures via the CLI.
#   2. Start the Electron app and open the database.
#   3. Select both assets via the gallery checkboxes.
#   4. Open the right sidebar.
#   5. Click "Download N assets".
#   6. Wait for the log line emitted when the save-assets-batch worker
#      task completes.
#   7. Confirm both saved files exist on disk in the test download folder.
#
# The folder picker is bypassed in test mode by PHOTOSPHERE_TEST_DOWNLOAD_FOLDER;
# the env var supplies the destination folder that the main process would
# otherwise choose via dialog.showOpenDialog.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 20 "download-multiple-assets"

SOURCE_DB="$TMP_DIR/test-db"
DOWNLOAD_DIR="$TMP_DIR/downloads"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

log_info "Pre-creating database and importing two fixtures..."
cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes || exit 1
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes || exit 1
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-2.png" --db "$SOURCE_DB" --yes || exit 1
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

# Tell the main process to skip the native folder picker and save assets
# directly into this folder.
export PHOTOSPHERE_TEST_DOWNLOAD_FOLDER="$DOWNLOAD_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Opening database..."
send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 2 assets loaded"
log_success "Database opened with 2 assets"

wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "Gallery items are in the DOM"

log_info "Selecting both gallery items..."
# The selection checkboxes are hidden (display:none) until selecting mode is on,
# so the first item has to be selected with a long press, the same gesture a
# user makes. Once selecting mode is on every checkbox becomes visible and the
# second item can be selected by clicking its checkbox. All thumbs share
# data-id="gallery-item-checkbox", so nth picks which one.
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}'
send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}'

log_info "Opening right sidebar..."
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}'

# Wait until the sidebar reports both assets selected before downloading. The second item's checkbox
# is display:none until the long press turns selecting mode on, so that click waits for the element
# to appear, and the driver handles each command independently: on a slow runner the download click
# overtook the still-waiting checkbox click and downloaded one asset instead of two.
wait_for_value "$APP_PORT" "download-selected-button" "Download 2 assets"

log_info "Clicking Download N assets..."
send_command "$APP_PORT" click '{"dataId":"download-selected-button"}'

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
