#!/bin/bash

# Mobile end-to-end LAN-share round trip over the device's own loopback. Unlike tests 7/8 (which drive
# only the sender-side UI), this dispatches a real receiver task and a real sender (find-receiver then
# send-payload) through the same TaskQueue the app uses, so the whole native stack runs on the device:
# UDP discovery, the self-signed TLS server, cert pinning, and the HTTPS payload transfer. It asserts the
# receiver actually delivered the exact secret payload the sender sent, proving a real transfer works.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 9 "share-roundtrip"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Running LAN-share round trip over loopback..."
response=$(curl -s --max-time 45 -X POST "http://localhost:$APP_PORT/lan-share-roundtrip" \
    -H "Content-Type: application/json" -d '{}' 2>&1)
log_info "Round-trip result: $response"

# The receiver delivers the exact secret value the sender sent; its presence proves an end-to-end
# transfer (a failed discovery/send would leave the delivered payload null and omit this value).
if ! echo "$response" | grep -q "roundtrip-value-42"; then
    log_error "Round trip did not deliver the payload. Response: $response"
    exit 1
fi

# Guard against a bridge-level failure being reported as ok.
if echo "$response" | grep -q '"ok":false'; then
    log_error "Round trip command reported failure. Response: $response"
    exit 1
fi

check_no_errors "$TMP_DIR"

log_success "Test 9 passed: share-roundtrip (real end-to-end transfer over loopback)"
