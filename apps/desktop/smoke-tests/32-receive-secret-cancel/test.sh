#!/bin/bash

# Cancelling a secret receive, then receiving again. The secret counterpart of 30.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
print_test_header 32 "receive-secret-cancel"


cleanup() {
    if [ -f "$TMP_DIR/sender/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/sender/app.pid")"
    fi
    if [ -f "$TMP_DIR/receiver/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/receiver/app.pid")"
    fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

write_vault_secret "$TMP_DIR/sender/vault" test-secret api-key "TESTAPIKEY123"

start_app "$TMP_DIR/receiver" 0
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

# --- 1. Wait for a sender that never comes, then cancel. ---

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

send_command "$RECEIVER_PORT" type '{"dataId":"receive-secret-code-input","text":"0000"}'
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}'

# The Cancel button only renders during the waiting step, so its presence proves the receive task is
# running and there is something to cancel.
wait_for_value "$RECEIVER_PORT" "receive-secret-cancel-button" "Cancel"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-cancel-button"}'

#
# An empty response means the request itself failed, which is not the same as the dialog having
# closed, and this loop used to treat the two alike: an app that had died read exactly like a
# cancelled dialog and satisfied the wait. The response is now required to have arrived before its
# value is believed, and still_waiting starts at "Cancel" so a run where every request failed ends in
# the failure below rather than in a pass.
elapsed=0
still_waiting="Cancel"
while [ "$elapsed" -lt 15 ]; do
    response=$(curl -sf "http://localhost:$RECEIVER_PORT/get-value?dataId=receive-secret-cancel-button" 2>/dev/null || true)
    if [ -n "$response" ]; then
        still_waiting=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ "$still_waiting" != "Cancel" ]; then
            break
        fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ "$still_waiting" = "Cancel" ]; then
    log_error "Receiver is still waiting for a sender after the receive was cancelled"
    exit 1
fi
log_success "The cancelled receive stopped and the dialog closed"

# --- 2. Receive again, this time with a real sender. ---

start_app "$TMP_DIR/sender" 960
SENDER_PORT="$APP_PORT"
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}'

code=""
elapsed=0
while [ "$elapsed" -lt 30 ]; do
    response=$(curl -sf "http://localhost:$SENDER_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
    log_error "Sender never displayed a pairing code"
    exit 1
fi
log_info "Pairing code: $code"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret saved"

if ! vault_has_secret "$TMP_DIR/receiver/vault" test-secret; then
    log_error "Receiver vault has no secret from the restarted receive"
    exit 1
fi
log_success "A receive started after a cancelled one paired and saved the secret"

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 32 passed: receive-secret-cancel"
