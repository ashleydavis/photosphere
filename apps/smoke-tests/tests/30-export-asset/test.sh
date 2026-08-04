#!/bin/bash

# Exercises the mobile asset-export cancel path (substep 12a): a download writes the file to a sandbox
# temp path, the export share sheet is cancelled, and downloadAsset aborts without reporting a
# completed download. The share sheet itself cannot be tapped by an automated test, so the outcome is
# staged via the stage-export command; the native temp-copy cleanup on each exit is covered by the
# platform ExportTemp unit tests. The export SUCCESS path (single and batch) is already covered by
# tests 19 and 20. Before this fix pickFile echoed its input, so the file landed in app-private sandbox
# storage and a success toast fired even though nothing was handed out.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 30 "export-asset"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a database with one asset under tmp and copy it into the sandbox.
create_database "$TMP_DIR/test-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"

send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery items rendered"

# Open the asset in the full-screen AssetView.
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

# --- Cancel aborts the flow and hands nothing out. ---
# Stage the export sheet to be cancelled, then download. The save-asset task writes the temp copy, the
# export sheet is cancelled, the temp copy is deleted, and downloadAsset returns before logging a
# completed download. Assert no "Download completed" line appears.
send_command "$APP_PORT" stage-export '{"exportOutcome":"cancelled"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1
sleep 3
if grep -q "Download completed" "$TMP_DIR/app.log"; then
    log_error "A cancelled export must not report a completed download"
    exit 1
fi

# Thumbnail/display fetches need the not-yet-built asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset:|Network Error'

log_success "Test 30 passed: export-asset"
