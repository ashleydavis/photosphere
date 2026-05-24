#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 22 "edit-database-origin"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)
NEW_ORIGIN="s3:my-bucket:/origin-database"

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

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes
cd "$DESKTOP_DIR"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

# Register the CLI-created database as an entry in databases.toml.
send_command "$APP_PORT" click '{"dataId":"add-database-button"}'
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'
wait_for_log "$TMP_DIR" "Database entry added"

# Open the Edit dialog from the row's edit button.
send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"
send_command "$APP_PORT" click '{"dataId":"edit-database-button"}'
wait_for_log "$TMP_DIR" "Edit database dialog opened"

# Type the new origin and save.
send_command "$APP_PORT" type "{\"dataId\":\"database-origin-input\",\"text\":\"$NEW_ORIGIN\"}"
send_command "$APP_PORT" click '{"dataId":"save-database-button"}'
wait_for_log "$TMP_DIR" "Database entry updated"

# Verify origin was persisted to .db/config.json (the canonical source of truth).
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

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 22 passed: edit-database-origin"
