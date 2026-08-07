#!/bin/bash

# Mobile port of desktop 5-add-secret. Navigates to the Secrets page and adds a secret. Uses
# only navigate/click/type, so it exercises how far the secrets flow gets on mobile before the
# vault write (platform provider) is missing.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 5 "add-secret"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

# The log line alone proved nothing: the app writes it straight after awaiting addSecret, so a
# keychain write that silently does nothing leaves it intact and this test passed with the secret
# never stored. Confirmed by dropping both secureStore.set calls and watching this test still pass.
# The secrets page renders one row per stored secret, so waiting for the row is the assertion that
# the secret actually reached the keychain and was enumerated back out of it.
wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"

check_no_errors "$TMP_DIR"

log_success "Test 5 passed: add-secret"
