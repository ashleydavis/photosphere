#!/bin/bash

# Renames a secret through the Edit dialog. On a desktop the vault is seeded with an api-key and checked afterwards: the new name holds
# the value and the old name is gone. On a phone the vault cannot be written from the host, so a secret is added through the Add Secret
# dialog (rename works for any type, so the default s3-credentials type is used) and only the edit is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 14 "rename-secret"

trap 'cleanup_apps "$TMP_DIR"' EXIT

RAW_KEY="sk-rename-me"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        mkdir -p "$TMP_DIR/vault"
        write_vault_secret "$TMP_DIR/vault" old-name api-key "$RAW_KEY"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

case "$PLATFORM" in
    android|ios)
        add_secret_via_ui "$APP_PORT" "old-name" "s3-credentials" "us-east-1" || exit 1
        # The secret's actions are in its card's menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"new-name"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        # has is false when the key is absent, and jq -e exits non-zero on a false result.
        if jq -e --arg name old-name 'has($name)' "$TMP_DIR/vault/vault.json" > /dev/null 2>&1; then
            log_error "Old vault entry 'old-name' still exists"
            exit 1
        fi

        if ! jq -e --arg name new-name 'has($name)' "$TMP_DIR/vault/vault.json" > /dev/null 2>&1; then
            log_error "New vault entry 'new-name' was not created"
            exit 1
        fi

        NEW_VALUE=$(jq -j --arg name new-name '.[$name].value' "$TMP_DIR/vault/vault.json")
        if [ "$NEW_VALUE" != "$RAW_KEY" ]; then
            log_error "Renamed entry's value was not preserved"
            log_error "Expected: $RAW_KEY"
            log_error "Actual:   $NEW_VALUE"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 14 passed: rename-secret"
