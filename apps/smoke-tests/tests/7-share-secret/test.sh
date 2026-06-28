#!/bin/bash

# Mobile port of desktop 7-share-secret. The desktop test runs two app windows (sender +
# receiver) and completes a LAN pairing. Two concurrent app instances are not feasible on a
# single emulator/simulator, so this port drives the sender side only: it opens the share flow
# and waits for a pairing code, surfacing whether LAN secret sharing works on mobile at all.
# The full two-party flow needs two devices and is follow-up work.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 7 "share-secret"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded" 20

send_command "$APP_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

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
    log_error "Failed to read pairing code from sender (LAN secret sharing not working on mobile)"
    exit 1
fi
log_info "Pairing code: $code"

check_no_errors "$TMP_DIR"

log_success "Test 7 passed: share-secret (sender side)"
