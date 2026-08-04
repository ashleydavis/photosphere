#!/bin/bash

# Mobile port of desktop 7-share-secret. The desktop test runs two app windows (sender +
# receiver) and completes a LAN pairing. Two concurrent app instances are not feasible on a
# single emulator/simulator, so this port drives the sender side only: it adds a secret, opens
# the share flow, and waits for a pairing code, surfacing whether the sender-side LAN secret
# share flow works on mobile. The full two-party transfer needs two devices and native
# networking (a later layer); until then the sender shows its pairing code and the background
# discovery task waits and times out gracefully.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 7 "share-secret"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add a secret so the Secrets page has a row with a Share button to click.

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"smoke-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

log_info "Waiting for pairing code..."
code=""
elapsed=0
while [ "$elapsed" -lt 20 ]; do
    response=$(curl -sf "http://$BRIDGE_HOST:$APP_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
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
