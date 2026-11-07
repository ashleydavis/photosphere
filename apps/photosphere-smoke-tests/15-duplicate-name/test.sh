#!/bin/bash

# Adds a secret whose name already exists and expects the duplicate-name guard to fire. On a desktop the conflicting secret is seeded in
# the vault, which is then checked to hold exactly one secret and to be a file that was not rewritten. On a phone the vault cannot be
# written from the host, so the first secret is added through the Add Secret dialog and only the guard is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 15 "duplicate-name"

trap 'cleanup_apps "$TMP_DIR"' EXIT

# Modification time, sub-second, so a rewrite inside the same second is still caught. GNU stat (Linux, Git Bash) and BSD stat (macOS)
# spell it differently, hence the fallback.
file_mtime() {
    stat -c %y "$1" 2>/dev/null || stat -f %Fm "$1"
}

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        mkdir -p "$TMP_DIR/vault"
        write_vault_secret "$TMP_DIR/vault" dup-secret s3-credentials \
            '{"region":"","accessKeyId":"","secretAccessKey":""}'
        ORIG_MTIME=$(file_mtime "$TMP_DIR/vault/vault.json")
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

case "$PLATFORM" in
    android|ios)
        add_secret_via_ui "$APP_PORT" "dup-secret" "s3-credentials" "us-east-1" || exit 1
        ;;
esac

# Try to add another secret with the same name.
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"dup-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "A secret named 'dup-secret' already exists"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        COUNT=$(jq 'length' "$TMP_DIR/vault/vault.json")
        if [ "$COUNT" -ne 1 ]; then
            log_error "Expected exactly 1 secret in the vault, found $COUNT"
            exit 1
        fi

        NEW_MTIME=$(file_mtime "$TMP_DIR/vault/vault.json")
        if [ "$ORIG_MTIME" != "$NEW_MTIME" ]; then
            log_error "Original vault file was overwritten by duplicate-add"
            log_error "Original mtime: $ORIG_MTIME, new mtime: $NEW_MTIME"
            exit 1
        fi
        ;;
esac

# The expected save error from the duplicate-name throw is allowed; any other [ERROR] line is a regression. The error is logged as two
# lines (a "Save error:" header and the message itself), so both are ignored.
check_no_errors "$TMP_DIR" "Save error:|A secret named 'dup-secret' already exists"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 15 passed: duplicate-name"
