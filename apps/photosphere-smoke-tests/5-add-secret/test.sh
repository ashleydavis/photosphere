#!/bin/bash

# Navigates to the Secrets page and adds a secret through the dialog, then checks the secret reached storage.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 5 "add-secret"

trap 'cleanup_apps "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

# The log line alone proves nothing: the app writes it straight after awaiting addSecret, so a vault write that silently does nothing
# leaves it intact. The secrets page renders one row per stored secret, so waiting for the row is the assertion that the secret was
# stored and read back out of it.
wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"

# Where the vault is a file the test can read (a desktop, with the plaintext vault the test mode selects), the secret is checked there
# too. This is the assertion that it reached storage and not only the page.
case "$PLATFORM" in
    linux|windows|macos)
        if ! vault_has_secret "$TMP_DIR/vault" test-secret; then
            log_error "The app reported 'Secret added' but the vault holds no secret named 'test-secret'"
            exit 1
        fi
        log_success "The secret is in the vault"
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 5 passed: add-secret"
