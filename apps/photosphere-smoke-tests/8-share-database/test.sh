#!/bin/bash

# Shares a database entry over the LAN through the real Share Database dialog. On a desktop two copies of the app run side by side: the
# sender holds a database entry that names an S3 credentials secret and an encryption key, the receiver types the sender's pairing
# code, reviews what arrived and saves it, and the receiver's databases list, databases.toml and vault then hold the entry and both
# secrets it carried. A phone cannot run two copies of the app on one device, so there only the sender side is driven: it registers a
# database, opens the share dialog and presses Send, and the pairing code appears.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 8 "share-database"

case "$PLATFORM" in
    android|ios)
        DB_NAME="test-db"

        trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

        # Wipe everything the app has stored on the device (its storage sandbox, the WebView's localStorage and the keychain) so this
        # test starts from a known state. Done before launch, with the app stopped, so nothing can write state back underneath it.
        "${PLATFORM}_reset_app_state" || exit 1

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # Create an empty database and seed it into the app sandbox, and add a database entry so the Databases page has a row with a
        # Share button to click. Adding auto-opens the database, so the (empty) database must be present to load cleanly.
        create_database "$TMP_DIR/$DB_NAME"
        "${PLATFORM}_seed_database" "$TMP_DIR/$DB_NAME" "$DB_NAME" || exit 1

        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"

        send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Add database dialog opened"

        send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
        send_command "$APP_PORT" type "$(jq -cn --arg text "$("${PLATFORM}_app_path" "$DB_NAME")" '{dataId: "database-path-input", text: $text}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
        wait_for_log "$TMP_DIR" "Database entry added"

        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"

        # Confirming the Add Database dialog registers the entry and then opens that database, which re-renders the card list. That
        # open runs after "Database entry added" is logged, so wait for it to settle before opening the menu: otherwise it lands
        # mid-test and tears the menu down before the action can be clicked. Polled from the navbar marker (rendered only while a
        # database is open) rather than a log line, because the open can complete either side of the page-loaded event and a log wait
        # would miss an early one. The navbar marker is not enough on its own: the open emits a second "Databases page loaded" render
        # after "Database opened", which lands after the marker appears and tears the menu down, so wait for that render too. When
        # this races, the share dialog never opens and the failure surfaces as the misleading "Failed to read pairing code from
        # sender".
        wait_for_value "$APP_PORT" database-photo-count "photos"
        wait_for_log "$TMP_DIR" "Database opened"
        wait_for_log "$TMP_DIR" "Databases page loaded"

        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"share-database-button"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

        log_info "Waiting for pairing code..."
        code="$(read_pairing_code "$APP_PORT" 20)" || {
            log_error "Failed to read pairing code from sender (LAN database sharing not working on mobile)"
            exit 1
        }
        log_info "Pairing code: $code"

        check_no_errors "$TMP_DIR"

        log_success "Test 8 passed: share-database (sender side)"
        ;;
    *)
        trap 'cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"' EXIT

        mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

        # Seed sender vault with S3 credentials
        write_vault_secret "$TMP_DIR/sender/vault" test-s3-key s3-credentials \
            '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"testsecret"}'

        # Seed sender vault with encryption key (raw PEM, the receiver derives the public key)
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP_DIR/sender/test-enc-key.pem" 2>/dev/null
        write_vault_secret_from_file "$TMP_DIR/sender/vault" \
            test-enc-key encryption-key "$TMP_DIR/sender/test-enc-key.pem"

        # Seed sender databases config (TOML format). The path is inside this test's own temporary directory. Nothing creates it (the
        # entry is here to be listed and shared, not opened), but a fixed machine-wide path is a thing two runs of this suite would
        # share.
        cat > "$TMP_DIR/sender/config/databases.toml" << TOML
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/smoke-test-db"
s3_key = "test-s3-key"
encryption_key = "test-enc-key"

TOML

        # Start sender app
        start_app "$TMP_DIR/sender"
        SENDER_PORT="$APP_PORT"
        wait_for_ready "$SENDER_PORT"

        send_command "$SENDER_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR/sender" "Databases page loaded"

        send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}' || exit 1
        # The dialog fills its name, description and path from the entry in an effect after it opens, and the Send button sends what the form
        # held when it was last drawn. A click sent straight after the one that opens the dialog lands before the form has been filled, which
        # would share a database with no name and no path. Asking the page for the button first gives it the turn it needs.
        wait_for_value "$SENDER_PORT" "share-database-send-button" "Send"
        send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

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

        send_command "$RECEIVER_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

        send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}" || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Database review step"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Database imported"

        # After import completes the list on the page behind the success dialog must already reflect the new database. The user should
        # not need to dismiss the dialog or hit Refresh for the row to appear.
        log_info "Waiting for receiver row to appear after import (before closing dialog)..."
        wait_for_value "$RECEIVER_PORT" "database-row-name-test-db" "test-db"

        # Assert receiver databases config contains the database entry
        if [ ! -f "$TMP_DIR/receiver/config/databases.toml" ]; then
            log_error "Expected $TMP_DIR/receiver/config/databases.toml to exist"
            exit 1
        fi

        if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
            log_error "Receiver databases.toml does not contain expected database name"
            exit 1
        fi

        # Assert receiver vault has the S3 credentials
        if ! vault_has_secret "$TMP_DIR/receiver/vault" test-s3-key; then
            log_error "Expected the receiver vault to hold a secret named 'test-s3-key'"
            exit 1
        fi

        # Assert receiver vault has the encryption key
        if ! vault_has_secret "$TMP_DIR/receiver/vault" test-enc-key; then
            log_error "Expected the receiver vault to hold a secret named 'test-enc-key'"
            exit 1
        fi

        check_no_errors "$TMP_DIR/sender"
        check_no_errors "$TMP_DIR/receiver"

        stop_app "$SENDER_PORT" "$TMP_DIR/sender"
        stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

        log_success "Test 8 passed: share-database"
        ;;
esac
