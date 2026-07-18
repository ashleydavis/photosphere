#!/bin/bash

# Adds a database entry, edits its origin, and saves. Electron verifies origin was
# persisted to .db/config.json on the host. Mobile drives the UI flow with a sandbox path.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 22 "edit-database-origin"

TMP_DIR="$TEST_DIR/tmp"
NEW_ORIGIN="s3:my-bucket:/origin-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating database with CLI..."
    create_database "$TMP_DIR/test-db"
    DB_PATH="$TMP_DIR/test-db"
else
    DB_PATH="test-db"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/test-db"
    seed_database "$TMP_DIR/test-db" "test-db"
fi

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"edit-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-origin-input\",\"text\":\"$NEW_ORIGIN\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"save-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry updated"

if [ "$PLATFORM" = "electron" ]; then
    CONFIG_PATH="$TMP_DIR/test-db/.db/config.json"
    if [ ! -f "$CONFIG_PATH" ]; then
        log_error "Expected database config at $CONFIG_PATH but file does not exist"
        exit 1
    fi

    NEW_ORIGIN="$NEW_ORIGIN" CONFIG_PATH="$CONFIG_PATH" python3 -c "
import json, os, sys
with open(os.environ['CONFIG_PATH']) as f:
    config = json.load(f)
expected = os.environ['NEW_ORIGIN']
actual = config.get('origin')
if actual != expected:
    print(f'FAIL: .db/config.json origin mismatch', file=sys.stderr)
    print(f'Expected: {expected!r}', file=sys.stderr)
    print(f'Actual:   {actual!r}', file=sys.stderr)
    sys.exit(1)
" || exit 1
fi

check_no_errors "$TMP_DIR"

log_success "Test 22 passed: edit-database-origin"
