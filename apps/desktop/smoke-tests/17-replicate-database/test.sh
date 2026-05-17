#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-images"

print_test_header 17 "replicate-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

SOURCE_DB="$TMP_DIR/source-db"
DEST_PARTIAL="$TMP_DIR/dest-partial"
DEST_FULL="$TMP_DIR/dest-full"

log_info "Pre-creating source database with CLI and importing a fixture..."
cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes
cd "$DESKTOP_DIR"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

# Register the source database on the Manage Databases page.
send_command "$APP_PORT" click '{"dataId":"add-database-button"}'
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}'
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$SOURCE_DB\"}"
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'
wait_for_log "$TMP_DIR" "Database entry added"

# Partial replication.
send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}'
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DEST_PARTIAL\"}"
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}'
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}'

wait_for_log "$TMP_DIR" "Replication completed for" 120

if [ ! -f "$DEST_PARTIAL/.db/files.dat" ]; then
    log_error "Partial replication did not produce $DEST_PARTIAL/.db/files.dat"
    exit 1
fi
if [ ! -f "$DEST_PARTIAL/.db/config.json" ]; then
    log_error "Partial replication did not produce $DEST_PARTIAL/.db/config.json"
    exit 1
fi
if ! grep -q "\"origin\"" "$DEST_PARTIAL/.db/config.json"; then
    log_error "Partial replication config.json does not contain origin"
    cat "$DEST_PARTIAL/.db/config.json"
    exit 1
fi

# The stored origin must be exactly the source path the user supplied to the dialog —
# otherwise the partial replica's lazy-fetch logic will route to a bad path on load.
EXPECTED_ORIGIN="$SOURCE_DB"
ACTUAL_ORIGIN=$(grep -oE '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' "$DEST_PARTIAL/.db/config.json" | sed -E 's/.*"origin"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')
if [ "$ACTUAL_ORIGIN" != "$EXPECTED_ORIGIN" ]; then
    log_error "Partial replica config.json origin does not match source path."
    log_error "  Expected: $EXPECTED_ORIGIN"
    log_error "  Actual:   $ACTUAL_ORIGIN"
    cat "$DEST_PARTIAL/.db/config.json"
    exit 1
fi

log_success "Partial replication produced expected files"

# Close the success dialog before opening the replica.
send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}'

# Open the partial replica and confirm its gallery loads with the same number of assets
# the source has (1, set above via the fixture import).
send_command "$APP_PORT" open-database "{\"path\":\"$DEST_PARTIAL\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 60
log_success "Partial replica opened with 1 asset"

# Full replication. Navigate away and back to force the databases page to remount
# (re-entering the same route doesn't trigger "Databases page loaded" again).
send_command "$APP_PORT" navigate '{"page":"secrets"}'
send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}'
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DEST_FULL\"}"
send_command "$APP_PORT" click '{"dataId":"replicate-mode-full"}'
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}'

wait_for_log "$TMP_DIR" "Replication completed for" 120

if [ ! -f "$DEST_FULL/.db/files.dat" ]; then
    log_error "Full replication did not produce $DEST_FULL/.db/files.dat"
    exit 1
fi
if [ ! -s "$DEST_FULL/.db/files.dat" ]; then
    log_error "Full replication produced an empty files.dat"
    exit 1
fi
log_success "Full replication produced expected files"

send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}'

# Open the full replica and confirm its gallery loads with the same number of assets.
send_command "$APP_PORT" open-database "{\"path\":\"$DEST_FULL\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 60
log_success "Full replica opened with 1 asset"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 17 passed: replicate-database"
