#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

source "$TEST_DIR/../lib/common.sh"

print_test_header 6 "add-database-entry"

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

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes
cd "$DESKTOP_DIR"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}'

wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"add-database-button"}'

wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"

send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'

wait_for_log "$TMP_DIR" "Database entry added"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
