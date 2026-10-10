#!/bin/bash

# Edits the region of an s3-credentials secret. On a desktop the vault is seeded with credentials stored as JSON with no label, and
# the vault is checked to still hold JSON with no label, the new region and the other two fields untouched. On a phone the vault
# cannot be written from the host, so the secret is added through the Add Secret dialog and only the edit is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 13 "edit-s3-credentials"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        mkdir -p "$TMP_DIR/vault"
        write_vault_secret "$TMP_DIR/vault" s3-creds-1 s3-credentials \
            '{"region":"us-east-1","accessKeyId":"AKIAOLD","secretAccessKey":"OLDSECRET"}'
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

case "$PLATFORM" in
    android|ios)
        add_secret_via_ui "$APP_PORT" "s3-cred" "s3-credentials" "us-east-1" || exit 1
        # The secret's actions are in its card's menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"eu-west-1"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        # The secret's value is itself a JSON document, so it is read out to its own file and then read field by field. jq -j writes
        # the string value raw with no trailing newline, so the file holds exactly the bytes the app stored.
        jq -j --arg name s3-creds-1 '.[$name].value' "$TMP_DIR/vault/vault.json" > "$TMP_DIR/credentials.json"

        # has is false when the key is absent, which is what "no label key" means here, and jq -e exits non-zero on a false result.
        if jq -e 'has("label")' "$TMP_DIR/credentials.json" > /dev/null 2>&1; then
            log_error "Vault value still contains a label key"
            exit 1
        fi

        SAVED_REGION=$(jq -j '.region' "$TMP_DIR/credentials.json")
        if [ "$SAVED_REGION" != "eu-west-1" ]; then
            log_error "Region was not updated, got: $SAVED_REGION"
            exit 1
        fi

        SAVED_ACCESS_KEY=$(jq -j '.accessKeyId' "$TMP_DIR/credentials.json")
        SAVED_SECRET_KEY=$(jq -j '.secretAccessKey' "$TMP_DIR/credentials.json")
        if [ "$SAVED_ACCESS_KEY" != "AKIAOLD" ] || [ "$SAVED_SECRET_KEY" != "OLDSECRET" ]; then
            log_error "Other s3 fields were not preserved: accessKeyId=$SAVED_ACCESS_KEY secretAccessKey=$SAVED_SECRET_KEY"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 13 passed: edit-s3-credentials"
