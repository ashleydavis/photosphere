#!/bin/bash

# Cancelling a secret share, then sharing again. Secrets go over the same LAN-share machinery and the
# same single LAN_SHARE_SOURCE task tag as databases, so this covers the secret half of the same
# cancel-and-restart behaviour that 29 covers for databases.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
print_test_header 31 "share-secret-cancel"


cleanup() {
    cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

write_vault_secret "$TMP_DIR/sender/vault" test-secret api-key "TESTAPIKEY123"

#
# Reads the pairing code the sender is displaying, waiting until it is a four digit code.
# Prints the code on stdout, or nothing if it never appeared.
#
read_pairing_code() {
    local port="$1"
    local elapsed=0
    local response=""
    local code=""

    while [ "$elapsed" -lt 30 ]; do
        response=$(curl -sf "http://localhost:$port/get-value?dataId=share-pairing-code" 2>/dev/null || true)
        code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
            echo "$code"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

start_app "$TMP_DIR/sender" 0
SENDER_PORT="$APP_PORT"
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

# --- 1. Start a share, then cancel it while it waits for a receiver. ---

send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}'

first_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the first share"
    exit 1
}
log_info "First pairing code: $first_code"

send_command "$SENDER_PORT" click '{"dataId":"share-secret-cancel-button"}'

#
# An empty response means the request itself failed, which is not the same as the pairing code having
# gone, and this loop used to treat the two alike: an app that had died read exactly like a cancelled
# share and satisfied the wait. The response is now required to have arrived before its value is
# believed, and still_showing starts at the code the sender was displaying so a run where every
# request failed ends in the failure below rather than in a pass.
elapsed=0
still_showing="$first_code"
while [ "$elapsed" -lt 15 ]; do
    response=$(curl -sf "http://localhost:$SENDER_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    if [ -n "$response" ]; then
        still_showing=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -z "$still_showing" ] || ! echo "$still_showing" | grep -qE '^[0-9]{4}$'; then
            break
        fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -n "$still_showing" ] && echo "$still_showing" | grep -qE '^[0-9]{4}$'; then
    log_error "Sender is still showing a pairing code after the share was cancelled"
    exit 1
fi
log_success "The cancelled share stopped and the dialog closed"

# --- 2. Share again and carry it through to a receiver. ---

send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}'

second_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the share started after the cancel"
    exit 1
}
log_info "Second pairing code: $second_code"

start_app "$TMP_DIR/receiver" 960
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$second_code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret saved"

if ! vault_has_secret "$TMP_DIR/receiver/vault" test-secret; then
    log_error "Receiver vault has no secret from the restarted share"
    exit 1
fi
log_success "A share started after a cancelled one paired and delivered the secret"

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 31 passed: share-secret-cancel"
