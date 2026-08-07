#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && native_pwd)"

print_test_header 12 "edit-api-key"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/vault"

# Seed the vault with a raw api-key (no JSON envelope), edit it via the
# UI and verify the round-trip preserves the raw-string format.
RAW_KEY="sk-test-1234567890ABCDEF"
write_vault_secret "$TMP_DIR/vault" api-key-1 api-key "$RAW_KEY"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

# Click the Edit button on the only row.
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Save without modification — the round-trip must preserve the raw key string.
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

# Assert the vault still contains the raw key string (not a JSON envelope).
SAVED_VALUE=$(jq -j --arg name api-key-1 '.[$name].value' "$TMP_DIR/vault/vault.json")

if [ "$SAVED_VALUE" != "$RAW_KEY" ]; then
    log_error "Vault value is no longer the raw API key"
    log_error "Expected: $RAW_KEY"
    log_error "Actual:   $SAVED_VALUE"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
