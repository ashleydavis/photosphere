#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 1 "launch-and-navigate"

TMP_DIR="$TEST_DIR/tmp"

cleanup() {
    stop_app "$APP_PORT" "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Navigate and confirm the command round-tripped through the bridge to the shared driver.
send_command "$APP_PORT" navigate '{"page":"/cloud"}'
wait_for_log "$TMP_DIR" "test-navigate: navigating to /cloud"

# Capture a screenshot host-side via the bridge.
send_command "$APP_PORT" screenshot "{\"outputPath\":\"$TMP_DIR/screenshot.png\"}"

check_no_errors "$TMP_DIR"

# Teardown (stop_app) is handled by the EXIT trap so it runs exactly once.
log_success "Test 1 passed: launch-and-navigate"
