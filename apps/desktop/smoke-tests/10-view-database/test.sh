#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 10 "view-database"

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

send_command "$APP_PORT" navigate '{"page":"secrets"}'

wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'

wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"smoke-geocoding"}'

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'

wait_for_log "$TMP_DIR" "Secret added"

send_command "$APP_PORT" navigate '{"page":"databases"}'

wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"add-database-button"}'

wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"

send_command "$APP_PORT" click '{"dataId":"select-geocoding-button"}'

send_command "$APP_PORT" click '{"dataId":"secret-select-button"}'

send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'

wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}'

wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"view-database-button"}'

wait_for_log "$TMP_DIR" "View database dialog opened"

send_command "$APP_PORT" click '{"dataId":"view-secret-geocoding-button"}'

wait_for_log "$TMP_DIR" "View secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}'

wait_for_log "$TMP_DIR" "Secret revealed"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 10 passed: view-database"
