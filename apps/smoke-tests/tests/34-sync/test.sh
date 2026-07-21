#!/bin/bash

# Substep 14e: an edit triggers a background sync, and the navbar sync spinner appears then clears.
#
# The mobile sync scheduler (mobile-sync-scheduler.ts) debounces an edit into a sync-database task, the
# worker runs it and emits sync-started / sync-completed messages, and the provider routes them to the
# navbar spinner via onSyncStarted/onSyncCompleted. This drives an edit and asserts the sync runs start
# to finish and that the spinner clears afterwards, rather than staying dead as it did with the stub.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 34 "sync"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="sync-db"
ORIGIN_NAME="sync-origin"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" reset-config '{}' || exit 1

# Seed a local database and a local origin to sync against (a second on-device database), so the sync
# runs end to end without needing S3 credentials.
#
# The worker's sync handler reads the origin from the database's own .db/config.json, not from the
# app's database list, so the origin has to be baked into the fixture before it is pushed to the
# device. A host-side copy of the fixture is made and its config rewritten, leaving the shared
# fixture untouched. Without this the handler returns early with "no origin configured" and never
# emits sync-started, which is exactly how this test failed before.
LOCAL_FIXTURE="$TMP_DIR/$DB_NAME"
rm -rf "$LOCAL_FIXTURE"
cp -r "$REPO_DIR/test/dbs/50-assets" "$LOCAL_FIXTURE"
printf '{"origin":"%s"}\n' "$ORIGIN_NAME" > "$LOCAL_FIXTURE/.db/config.json"

"${PLATFORM}_seed_database" "$LOCAL_FIXTURE" "$DB_NAME"
"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/50-assets" "$ORIGIN_NAME"
send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened"

# Allow automatic sync, then make an edit to trigger the debounced sync.
send_command "$APP_PORT" set-sync-allowed '{"allowed":true}' || exit 1
send_command "$APP_PORT" notify-database-edited '{}' || exit 1

# The sync runs start to finish. These are observed from the append-only app log rather than by
# polling navbar-sync-state for "syncing": the sync of an already-in-sync local origin can finish in
# well under the 1s poll interval, so polling for the transient "syncing" value is a race that can
# miss a sync that genuinely ran. The provider logs these two lines from the same sync-started /
# sync-completed handlers that flip isSyncing, so they are an exact, race-free proxy for the spinner
# turning on and off.
wait_for_log "$TMP_DIR" "Sync started"
wait_for_log "$TMP_DIR" "Sync completed"

# ...and the navbar spinner has cleared back to rest now the sync has completed.
wait_for_value "$APP_PORT" "navbar-sync-state" "idle" 60

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'

log_success "Test 34 passed: sync"
