#!/bin/bash

# Adds a database entry with a geocoding secret, then views the database and reveals the secret. On a desktop the database and the
# api-key secret are made with the CLI, the secret in the vault the app uses. On a phone the vault cannot be written from the host, so
# the secret is added through the Add Secret dialog and the database is copied into the sandbox.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 10 "view-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_reset_app_state" || exit 1
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        ;;
    *)
        DATABASE_PATH="$TMP_DIR/test-db"
        ;;
esac

create_database "$TMP_DIR/test-db"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        log_info "Pre-creating api-key secret with the CLI (using the same vault as the app)..."
        if ! (PHOTOSPHERE_CONFIG_DIR="$TMP_DIR/config" \
            PHOTOSPHERE_VAULT_DIR="$TMP_DIR/vault" \
            PHOTOSPHERE_VAULT_TYPE=plaintext \
            "$PHOTOSPHERE_ZIG_CLI" secrets add --yes --type api-key --name smoke-geocoding --value "fake-geocoding-key"); then
            log_error "Adding the api-key secret with the CLI failed"
            exit 1
        fi
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db" || exit 1
        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        add_secret_via_ui "$APP_PORT" "geo-key" "api-key" "the-geocoding-key" || exit 1
        ;;
esac

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

case "$PLATFORM" in
    android|ios)
        # The Add button is in the page's actions menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"select-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "Select secret modal ready"

send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

case "$PLATFORM" in
    android|ios)
        # Confirming the dialog registers the entry and then opens the database, which re-renders the card list. That open runs after
        # "Database entry added" is logged, so wait for it to settle before opening the menu, or it tears the menu down before the
        # action can be clicked.
        wait_for_value "$APP_PORT" database-photo-count "photos"
        wait_for_log "$TMP_DIR" "Database opened"
        wait_for_log "$TMP_DIR" "Databases page loaded"
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"view-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "View database dialog opened"

send_command "$APP_PORT" click '{"dataId":"view-secret-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 10 passed: view-database"
