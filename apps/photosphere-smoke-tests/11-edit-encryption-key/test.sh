#!/bin/bash

# Edits an encryption-key secret and saves it unchanged. On a desktop the vault is seeded with a raw PEM (no JSON envelope), the format
# the Receive Secret flow produces and that once crashed the Edit dialog, and the vault is checked to still hold exactly that PEM. On a
# phone the vault cannot be written from the host, so the secret is added through the Add Secret dialog with an empty PEM (the driver
# cannot type into the PEM textarea), which covers the add-then-edit path for the type but not the PEM value.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 11 "edit-encryption-key"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        mkdir -p "$TMP_DIR/vault"
        printf '%s' "-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQ
-----END PRIVATE KEY-----
" > "$TMP_DIR/raw.pem"
        write_vault_secret_from_file "$TMP_DIR/vault" enc-key-1 encryption-key "$TMP_DIR/raw.pem"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

case "$PLATFORM" in
    android|ios)
        add_secret_via_ui "$APP_PORT" "enc-key" "encryption-key" "" || exit 1
        # The secret's actions are in its card's menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Save without modification. The round trip must preserve the raw PEM format.
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        # Compared with cmp against a file, not as a shell string, because command substitution strips trailing newlines and the PEM's
        # trailing newline is exactly what this checks survived the round trip. -b keeps jq's output in binary mode: on Windows jq
        # writes stdout in text mode by default, which would turn each newline into CRLF and fail the comparison even when the value
        # round-tripped perfectly. The flag does nothing on Linux and macOS.
        jq -jb --arg name enc-key-1 '.[$name].value' "$TMP_DIR/vault/vault.json" > "$TMP_DIR/saved.pem"
        if ! cmp -s "$TMP_DIR/raw.pem" "$TMP_DIR/saved.pem"; then
            log_error "Vault value differs from the raw PEM"
            exit 1
        fi

        SAVED_TYPE=$(jq -j --arg name enc-key-1 '.[$name].type' "$TMP_DIR/vault/vault.json")
        if [ "$SAVED_TYPE" != "encryption-key" ]; then
            log_error "Type field changed: $SAVED_TYPE"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
