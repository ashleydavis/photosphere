#!/bin/bash

# Mobile port of desktop 1-load-fixture. Opens a fixture database and expects the gallery to
# load 50 assets. On mobile this requires the app to read a database (open-database), which is
# not implemented yet, so the test fails fast at that command, pinpointing the gap.
#
# Desktop seeds nothing here (it points at the checked-in test/dbs/50-assets fixture on the host
# filesystem). On mobile the fixture would need to be pushed to device storage once mobile
# storage lands.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 1 "load-fixture"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" open-database "{\"path\":\"$TMP_DIR/50-assets\"}" || exit 1

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" 20

check_no_errors "$TMP_DIR"

log_success "Test 1 passed: load-fixture"
