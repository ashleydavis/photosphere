#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 5 "add-secret"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'

wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'

wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}'

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'

wait_for_log "$TMP_DIR" "Secret added"

# The log line alone proved nothing: the app writes it straight after awaiting addSecret, so a vault
# write that silently does nothing leaves it intact and this test passed with the secret never
# stored. Confirmed by dropping the vault-set invoke and watching this test still pass. Reading the
# vault back is the assertion that the secret actually reached storage.
if ! vault_has_secret "$TMP_DIR/vault" test-secret; then
    log_error "The app reported 'Secret added' but the vault holds no secret named 'test-secret'"
    exit 1
fi
log_success "The secret is in the vault"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 5 passed: add-secret"
