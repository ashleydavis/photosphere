#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && pwd)"

source "$TEST_DIR/../lib/common.sh"

print_test_header 1 "load-fixture"

TMP_DIR="$TEST_DIR/tmp"
FIXTURE_DB="$REPO_DIR/test/dbs/50-assets"
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

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "{\"path\":\"$FIXTURE_DB\"}"

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 1 passed: load-fixture"
