#!/bin/bash

# Proves the LAN-share timeout window is honoured on device: with no receiver on the network the share
# flow must keep searching for its full 60 second window before it reports failure. That wait is driven
# by the embedded engine's virtual-clock timer, so this exercises whether the native timer pump advances
# the virtual clock at real-time rate. Before step 20 the Android pump fired the earliest timer every
# loop iteration with no budget, racing the clock far ahead of real time and collapsing the 60s window
# into roughly 12s, so the device gave up long before a peer could appear. With the pump given a real
# elapsed budget (matching iOS) the window lasts a real ~60s.
#
# This drives the real user path: it adds a secret, opens the share dialog and presses Send, exactly as
# test 7 does, then times how long the dialog takes to report "No receiver found".

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 37 "lan-share-timeout"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, then add a secret so the Secrets page has a row with a Share button to click.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"timeout-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

# The pairing code appears the moment the search starts, so it marks the beginning of the 60s window.
log_info "Waiting for the pairing code that marks the start of the search..."
code=""
waited=0
while [ "$waited" -lt 20 ]; do
    response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
    log_error "Share flow never started searching (no pairing code shown)"
    exit 1
fi

start_seconds=$(date +%s)
log_info "Search started with pairing code $code. Waiting for it to give up..."

# No receiver is on the network, so the dialog must eventually show its error alert. Poll well past the
# 60s window so a correct run is never cut short by the poll loop itself.
message=""
waited=0
while [ "$waited" -lt 120 ]; do
    response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=share-error-message" 2>/dev/null || true)
    message=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$message" ]; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

elapsed=$(( $(date +%s) - start_seconds ))

if [ -z "$message" ]; then
    log_error "Share dialog never reported a result after ${elapsed}s (the search did not give up)"
    exit 1
fi

# It must fail because no receiver was found, not for an unrelated reason (e.g. an unreadable secret).
if ! echo "$message" | grep -q "No receiver found"; then
    log_error "Share failed for the wrong reason: $message"
    exit 1
fi

log_info "Search gave up after ${elapsed}s (expected close to 60s)."

# The old no-budget pump collapsed the window to ~12s, so anything below 50s proves the virtual clock
# is still racing ahead of real time.
if [ "$elapsed" -lt 50 ]; then
    log_error "LAN-share window collapsed to ${elapsed}s (< 50s): the virtual clock is racing ahead of real time."
    exit 1
fi

check_no_errors "$TMP_DIR"

log_success "Test 37 passed: lan-share-timeout (the 60s window lasts a real ~60s on device)"
