#!/bin/bash

# Edits an api-key secret and saves it unchanged. On a desktop the vault is seeded with a raw key (no JSON envelope) and checked to
# still hold exactly that key. On a phone the vault cannot be written from the host, so the secret is added through the Add Secret
# dialog and only the add-then-edit path is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 12 "edit-api-key"

trap 'cleanup_apps "$TMP_DIR"' EXIT

RAW_KEY="sk-test-1234567890ABCDEF"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        mkdir -p "$TMP_DIR/vault"
        write_vault_secret "$TMP_DIR/vault" api-key-1 api-key "$RAW_KEY"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

case "$PLATFORM" in
    android|ios)
        add_secret_via_ui "$APP_PORT" "api-key" "api-key" "the-api-key-value" || exit 1
        # The secret's actions are in its card's menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Save without modification. The round trip must preserve the raw key string.
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        SAVED_VALUE=$(jq -j --arg name api-key-1 '.[$name].value' "$TMP_DIR/vault/vault.json")
        if [ "$SAVED_VALUE" != "$RAW_KEY" ]; then
            log_error "Vault value is no longer the raw API key"
            log_error "Expected: $RAW_KEY"
            log_error "Actual:   $SAVED_VALUE"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
