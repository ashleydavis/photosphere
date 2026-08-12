#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 7 "share-secret"

cleanup() {
    cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

# Seed sender vault with a test secret
write_vault_secret "$TMP_DIR/sender/vault" test-secret api-key "TESTAPIKEY123"

# Start sender app
start_app "$TMP_DIR/sender" 0
SENDER_PORT="$APP_PORT"
# The variable name is passed as a second argument so wait_for_ready can write back the port the app
# is actually on. Fixes the intermittent failure where a relaunched app was addressed on its old port: when the first
# launch times out, wait_for_ready relaunches the app, which binds a new OS-assigned port. Without
# the write-back the caller kept posting to the dead port and the test failed with
# "curl failed (exit N) posting to ..." followed by an unrelated-looking log-pattern timeout.
wait_for_ready "$SENDER_PORT" SENDER_PORT

send_command "$SENDER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}'

# Wait for pairing code element to be populated, then read it
log_info "Waiting for pairing code..."
code="$(read_pairing_code "$SENDER_PORT")" || {
    log_error "Failed to read pairing code from sender"
    exit 1
}
log_info "Pairing code: $code"

# Start receiver app
start_app "$TMP_DIR/receiver" 960
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT" RECEIVER_PORT

send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret saved"

# After import completes the list on the page behind the success dialog must already reflect the
# new secret — the user should not need to dismiss the dialog or hit Refresh for the row to appear.
log_info "Waiting for receiver row to appear after import (before closing dialog)..."
wait_for_value "$RECEIVER_PORT" "secret-row-name-test-secret" "test-secret"

# Assert receiver vault contains the secret
if ! vault_has_secret "$TMP_DIR/receiver/vault" test-secret; then
    log_error "Expected the receiver vault to hold a secret named 'test-secret'"
    exit 1
fi

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 7 passed: share-secret"
