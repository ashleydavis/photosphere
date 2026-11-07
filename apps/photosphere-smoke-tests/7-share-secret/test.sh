#!/bin/bash

# Shares a secret over the LAN through the real Share Secret dialog. On a desktop two copies of the app run side by side: the sender
# holds a secret in its vault, the receiver types the sender's pairing code, reviews what arrived and saves it, and the receiver's vault
# then holds the secret and its list shows the new row behind the success dialog. A phone cannot run two copies of the app on one device,
# so there only the sender side is driven: it adds a secret, opens the share dialog and presses Send, and the pairing code appears.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 7 "share-secret"

case "$PLATFORM" in
    android|ios)
        trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

        # Wipe everything the app has stored on the device (its storage sandbox, the WebView's localStorage and the keychain) so this
        # test starts from a known state. Done before launch, with the app stopped, so nothing can write state back underneath it.
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
        code="$(read_pairing_code "$APP_PORT" 20)" || {
            log_error "Failed to read pairing code from sender (LAN secret sharing not working on mobile)"
            exit 1
        }
        log_info "Pairing code: $code"

        check_no_errors "$TMP_DIR"

        log_success "Test 7 passed: share-secret (sender side)"
        ;;
    *)
        trap 'cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"' EXIT

        mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

        # Seed sender vault with a test secret
        write_vault_secret "$TMP_DIR/sender/vault" test-secret api-key "TESTAPIKEY123"

        # Start sender app
        start_app "$TMP_DIR/sender"
        SENDER_PORT="$APP_PORT"
        wait_for_ready "$SENDER_PORT"

        send_command "$SENDER_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

        send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}' || exit 1
        send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

        # Wait for pairing code element to be populated, then read it
        log_info "Waiting for pairing code..."
        code="$(read_pairing_code "$SENDER_PORT")" || {
            log_error "Failed to read pairing code from sender"
            exit 1
        }
        log_info "Pairing code: $code"

        # Start receiver app
        start_app "$TMP_DIR/receiver"
        RECEIVER_PORT="$APP_PORT"
        wait_for_ready "$RECEIVER_PORT"

        send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

        send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}" || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secret review step"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secret saved"

        # After import completes the list on the page behind the success dialog must already reflect the new secret. The user should not
        # need to dismiss the dialog or hit Refresh for the row to appear.
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
        ;;
esac
