#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 0 "launch-and-navigate"

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
#
# Both the command's status and the file it is supposed to produce are checked. Neither used to be:
# the screenshot step could fail outright, or write nothing, and this test still passed, so the one
# thing it claims to cover beyond navigation was not covered at all.
send_command "$APP_PORT" screenshot "{\"outputPath\":\"$TMP_DIR/screenshot.png\"}" || exit 1
if [ ! -s "$TMP_DIR/screenshot.png" ]; then
    log_error "The screenshot command reported success but wrote no file at $TMP_DIR/screenshot.png"
    exit 1
fi
log_success "The bridge captured a screenshot"

check_no_errors "$TMP_DIR"

# Teardown (stop_app) is handled by the EXIT trap so it runs exactly once.
log_success "Test 1 passed: launch-and-navigate"
