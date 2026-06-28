#!/bin/bash

# Mobile port of desktop 8-share-database. Like 7-share-secret, the desktop test runs two app
# windows; this port drives the sender side only (single emulator/simulator) and waits for a
# pairing code, surfacing whether LAN database sharing works on mobile. The full two-party flow
# needs two devices and is follow-up work.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 8 "share-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"share-database-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

log_info "Waiting for pairing code..."
code=""
elapsed=0
while [ "$elapsed" -lt 20 ]; do
    response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
    log_error "Failed to read pairing code from sender (LAN database sharing not working on mobile)"
    exit 1
fi
log_info "Pairing code: $code"

check_no_errors "$TMP_DIR"

log_success "Test 8 passed: share-database (sender side)"
