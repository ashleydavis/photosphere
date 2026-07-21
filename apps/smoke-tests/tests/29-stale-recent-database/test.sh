#!/bin/bash

# Mobile-only smoke test for step 11 (checkDatabaseExists). Opens a real database, then taps a stale
# recent entry whose files were never staged on the device. Asserts the shared "Database not found"
# guard fires (a warning toast) and the already-open database is left untouched. Before the fix,
# checkDatabaseExists returned true unconditionally, so tapping a stale recent entry closed the open
# database and switched to a dead path; this test would fail against that stub (no warning toast, and
# the photo-count marker disappears because the open database was closed).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 29 "stale-recent-database"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Deterministic start.
send_command "$APP_PORT" reset-config '{}' || exit 1

# Seed a real database on the device so there is an open database to leave alone.
create_database "$TMP_DIR/test-db"
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "$DB_NAME"
send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1

# Seed the recent list with the real database (index 0) plus a stale entry (index 1) whose files were
# never staged on the device, so checkDatabaseExists must report the stale entry absent.
send_command "$APP_PORT" seed-recent "{\"recent\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"},{\"name\":\"stale-db\",\"path\":\"stale-db\"}]}" || exit 1

# Open the real database (the direct-open path, which the sidebar's database-opened event refreshes
# the recent list from).
send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed"

# The navbar photo-count marker is rendered only while a database is open, so it is the observable
# proof the open database survives. Poll for it: the marker is committed on the React re-render that
# follows the load-assets completion log, a tick later than the log line itself.
wait_for_value "$APP_PORT" database-photo-count "photos"

# Open the sidebar and tap the stale recent entry (index 1).
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
sleep 1
send_command "$APP_PORT" click '{"dataId":"open-recent-database-button-1"}' || exit 1

# The guard must fire: a "Database not found" warning toast appears.
wait_for_value "$APP_PORT" toast-message "Database not found"

# ...and the originally-open database is left untouched (its photo-count marker is still present).
assert_value "$APP_PORT" database-photo-count "photos"

# Thumbnail fetches require the not-yet-built mobile asset-serving layer; ignore only those errors.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 29 passed: stale-recent-database"
