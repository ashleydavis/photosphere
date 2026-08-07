#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"

print_test_header 1 "load-fixture"

FIXTURE_DB="$REPO_DIR/test/dbs/50-assets"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "{\"path\":\"$FIXTURE_DB\"}"

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 1 passed: load-fixture"
