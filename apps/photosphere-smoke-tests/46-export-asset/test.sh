#!/bin/bash

# Exercises the asset-export cancel path: the save dialog (a desktop) or the export share sheet (a phone) is cancelled, and
# downloadAsset aborts without reporting a completed download. Neither can be tapped by an automated test, so the outcome is staged
# with ${PLATFORM}_cancel_next_download; on a phone the native temp-copy cleanup on each exit is covered by the platform ExportTemp unit
# tests. The export SUCCESS path (single and batch) is covered by tests 19 and 20. Were the export to echo its input, the file would
# land in app-private storage and a success toast would fire even though nothing was handed out.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 46 "export-asset"


trap 'cleanup_apps "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage, the web view's data and the keychain) so this test starts from a known
# state. Done before launch, with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

# Create a database with one asset under tmp and copy it into the app's storage.
create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db" || exit 1
DB_PATH="$("${PLATFORM}_app_path" "test-db")"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DB_PATH" '{path: $path}')" || exit 1
wait_for_log "$TMP_DIR" "Gallery items rendered"

# Open the asset in the full-screen AssetView.
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

# --- Cancel aborts the flow and hands nothing out. ---
# Stage the export sheet to be cancelled, then download. The save-asset task writes the temp copy, the export sheet is cancelled, the
# temp copy is deleted, and downloadAsset returns before logging a completed download. Assert no "Download completed" line appears.
"${PLATFORM}_cancel_next_download" "$APP_PORT" || exit 1
send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1

# Waiting for the cancel to be reported, rather than sleeping a fixed time and checking that nothing was logged. A download that never
# started at all logs no completion either, so a button that did nothing would read exactly like a working cancel, and on a loaded
# machine a download that was merely slow would read the same way too.
wait_for_log "$TMP_DIR" "Download cancelled: test-1.jpeg"

# ...and having cancelled, it must not also claim to have completed.
if grep -q "Download completed" "$TMP_DIR/app.log"; then
    log_error "A cancelled export must not report a completed download"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 46 passed: export-asset"
