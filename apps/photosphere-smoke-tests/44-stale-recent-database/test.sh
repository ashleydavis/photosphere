#!/bin/bash

# Opens a real database, then taps a stale recent entry whose files were never staged on the device. Asserts the shared "Database not
# found" guard fires (a warning toast) and the already-open database is left untouched. Were the existence check to answer true
# unconditionally, tapping a stale recent entry would close the open database and switch to a dead path; this test would then fail (no
# warning toast, and the photo-count marker disappears because the open database was closed).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 44 "stale-recent-database"

DB_NAME="test-db"
STALE_NAME="stale-db"

trap 'cleanup_apps "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage, the web view's data and the keychain) so this test starts from a known
# state. Done before launch, with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

# Seed a real database on the device so there is an open database to leave alone.
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "$DB_NAME" || exit 1
DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"
STALE_PATH="$("${PLATFORM}_app_path" "$STALE_NAME")"

# The recent list holds the real database (index 0) plus a stale entry (index 1) whose files were never staged on the device, so the
# existence check must report the stale entry absent. The stale entry is configured too, because recents are stored as names and
# resolved against the configured-databases list: an unconfigured recent is dropped on read and would never render, so the stale case
# could not arise.
"${PLATFORM}_seed_databases_config" \
    "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"},{\"name\":\"$STALE_NAME\",\"path\":\"$STALE_PATH\"}]" \
    "[\"$DB_NAME\",\"$STALE_NAME\"]" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Open the real database (the direct-open path, which the sidebar's database-opened event refreshes the recent list from).
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DB_PATH" '{path: $path}')" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed"

# The navbar photo-count marker is rendered only while a database is open, so it is the observable proof the open database survives.
# Poll for it: the marker is committed on the React re-render that follows the load-assets completion log, a tick later than the log
# line itself.
wait_for_value "$APP_PORT" database-photo-count "photos"

# Open the sidebar and tap the stale recent entry (index 1). Waiting for the entry to render replaces a fixed pause: the sidebar fills
# its recent list after it opens.
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
wait_for_value "$APP_PORT" "open-recent-database-button-1" "$STALE_NAME"
send_command "$APP_PORT" click '{"dataId":"open-recent-database-button-1"}' || exit 1

# The guard must fire: a "Database not found" warning toast appears.
wait_for_value "$APP_PORT" toast-message "Database not found"

# ...and the originally-open database is left untouched (its photo-count marker is still present).
assert_value "$APP_PORT" database-photo-count "photos"

check_no_errors "$TMP_DIR"

log_success "Test 44 passed: stale-recent-database"
