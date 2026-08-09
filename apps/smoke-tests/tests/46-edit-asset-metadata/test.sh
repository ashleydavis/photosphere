#!/bin/bash

# Editing an asset's metadata on device and having the edit survive a reopen.
#
# This covers the gallery EDIT path: persistDatabaseOps in
# packages/user-interface/src/context/asset-database-source.tsx POSTs the metadata ops to
# /apply-database-ops on the app's own asset server, which on mobile runs inside the embedded JS
# engine over the engine's TCP stream shim. Nothing else in either mobile suite exercises it. Test 18
# looks like it should, but moving assets between databases goes through a background move-assets
# task and never touches this endpoint; every other on-device write in the suite is a background task
# too. So the one route the UI uses to change a record has had no test at all.
#
# The assertion is deliberately made after closing and reopening the database, rather than by reading
# the field straight back. The description input is bound to React state that onUpdateDescription sets
# before the POST is even sent, so reading it in place passes whether or not a single byte reached the
# disk. Reopening throws that state away and loads the record from storage, so only a persisted edit
# can satisfy it.
#
# A failure here is silent in the app log by design of the code under test, not by oversight: the
# write goes out from inside a 500ms lodash debounce with nothing awaiting it, and the app installs no
# unhandledrejection handler, so a rejected POST leaves no trace anywhere. If this test times out on
# the reopened description with nothing in app.log to explain it, that is what has happened.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 46 "edit-asset-metadata"

DB_NAME="edit-db"
DESCRIPTION="Edited on the device"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# One asset is all this needs: the endpoint is the subject, not the volume.
create_database "$TMP_DIR/$DB_NAME" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1
# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task
# completes in either order, so a sequential wait for one then the other is racy. Wait for the gallery
# to render the item, which is the signal needed to click the thumbnail.
wait_for_log "$TMP_DIR" "Gallery items rendered"

# --- 1. Type a description into the asset's info panel. ---

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"asset-description-input\",\"text\":\"$DESCRIPTION\"}" || exit 1

# The field holding the text proves only that the keystrokes reached React. It is asserted anyway, so
# that a failure below can be read as "the edit did not persist" rather than "the typing never landed".
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The description was typed into the info panel"

# --- 2. Close the database, throwing away everything held in memory. ---

# Closing the asset view unmounts AssetInfo, whose unmount effect flushes the 500ms description
# debounce, so the write is issued here rather than being left to a timer the test would have to
# sleep out.
send_command "$APP_PORT" click '{"dataId":"asset-view-close-button"}' || exit 1

# Wait for the write to land before closing the database, because closing it is what would destroy an
# unfinished one: closeDatabase shuts the load queue down and notifies the platform, and on mobile
# that tears down the engine work the request is being served by. Without this wait the test passed on
# an idle emulator and failed under a full parallel run, which is the worst way for a test to be
# wrong: it looks solid until the suite is busy, and then it blames the app.
wait_for_log "$TMP_DIR" "Database ops applied"

send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1
wait_for_value "$APP_PORT" "no-database-loaded" "."
log_success "The database was closed, so nothing about the edit is left in memory"

# --- 3. Reopen it and read the description back off the disk. ---

send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1
wait_for_log "$TMP_DIR" "Gallery items rendered"

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"
send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1

# The whole test. The record was reloaded from storage, so this can only match if the metadata op
# reached /apply-database-ops and was applied.
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The edit survived closing and reopening the database, so it reached the database on disk"

# Thumbnail/display fetches need the asset-serving layer; ignore only those, as test 19 does.
check_no_errors "$TMP_DIR" 'Failed to load asset:|Network Error' || exit 1

log_success "Test 46 passed: edit-asset-metadata"
