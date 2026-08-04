#!/bin/bash

# Mobile-only test (25+; the 0-24 range mirrors the desktop suite, which has no prefetch test).
# Exercises the prefetch-database handler registered in mobile-worker-entry.ts: replicates a
# database partially (a partial replica copies only the merkle trees, not thumbnails), opens the
# partial replica so load-assets fire-and-forget queues a prefetch-database task, and asserts the
# prefetch copied the missing thumbnails into the local replica on device. Without the handler the
# partial database silently never prefetches and its gallery stays blank.
#
# The source database is opened exactly once here (the auto-open when its entry is added). Opening it
# a second time would cancel its task source, after which the replicate task queued against that same
# source is dropped and never runs.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 36 "prefetch-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Create a source database with one real asset (so it has a thumbnail to prefetch)
# and copy it into the app sandbox. Clear any partial replica from a previous run so the destination
# starts empty.
"${PLATFORM}_reset_path" "dest-partial"
create_database "$TMP_DIR/source-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
"${PLATFORM}_seed_database" "$TMP_DIR/source-db" "source-db"

# Register the source database, then replicate it partially. The partial replica copies only the
# merkle trees and README (no thumb/ directory), and records origin = the source path.
send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"source-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Adding the entry also opens that database, which re-renders the card list. That open runs after
# "Database entry added" is logged, so wait for it to settle before opening the menu: otherwise it
# lands mid-test and tears the menu down before the action can be clicked, and the click falls
# through to the card and merely re-opens the database. Polled from the navbar marker (rendered only
# while a database is open) rather than a log line, because the open can complete either side of the
# page-loaded event and a log wait would miss an early one. Same wait as test 8. The navbar marker is
# no longer enough on its own: the open now emits a second "Databases page loaded" render after
# "Database opened", which lands after the marker appears and tears the menu down, so wait for that
# render too.
wait_for_value "$APP_PORT" database-photo-count "photos"
wait_for_log "$TMP_DIR" "Database opened"
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"

# Open the partial replica. load-assets sees the partial flag and fire-and-forget queues a
# prefetch-database task, which copies the missing thumbnails from origin (the source database) into
# the local replica.
send_command "$APP_PORT" open-database '{"path":"dest-partial"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed"

# The prefetch is proven by its effect on device storage: the partial replica's thumb directory,
# absent after a partial replicate, becomes non-empty once prefetch-database has run. If the handler
# were unregistered the directory would stay absent and this wait would time out.
if ! "${PLATFORM}_wait_for_file" "dest-partial/thumb"; then
    log_error "Partial database did not prefetch: dest-partial/thumb never appeared on device"
    exit 1
fi
log_success "Partial database prefetched thumbnails into the local replica"

# Thumbnail fetches require the not-yet-built mobile asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 36 passed: prefetch-database"
