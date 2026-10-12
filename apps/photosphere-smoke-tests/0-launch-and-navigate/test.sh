#!/bin/bash

# The app launches, a navigate command sent over the test control connection reaches the page's shared test driver, and a screenshot
# command writes a picture of the window to the path it is given.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 0 "launch-and-navigate"

trap 'cleanup_apps "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Navigate and confirm the command round-tripped through the bridge to the shared driver.
send_command "$APP_PORT" navigate '{"page":"/cloud"}' || exit 1
wait_for_log "$TMP_DIR" "test-navigate: navigating to /cloud"

# Both the command's status and the file it is supposed to produce are checked, because a screenshot step that failed outright or wrote
# nothing would otherwise leave this test passing.
send_command "$APP_PORT" screenshot "{\"outputPath\":\"$TMP_DIR/screenshot.png\"}" || exit 1
if [ ! -s "$TMP_DIR/screenshot.png" ]; then
    log_error "The screenshot command reported success but wrote no file at $TMP_DIR/screenshot.png"
    exit 1
fi
log_success "The bridge captured a screenshot"

check_no_errors "$TMP_DIR" || exit 1

log_success "Test 0 passed: launch-and-navigate"
