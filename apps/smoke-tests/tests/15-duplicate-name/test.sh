#!/bin/bash

# Mobile port of desktop 15-duplicate-name. Adds a secret whose name already exists and expects
# the duplicate-name guard to fire. Desktop seeds the conflicting secret on the host vault; on
# mobile the vault lives on the device, so the precondition needs device-side seeding.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 15 "duplicate-name"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add the first secret through the real Add Secret UI, then adding a second of the same name must
# trigger the duplicate-name guard.

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

add_secret_via_ui "$APP_PORT" "dup-secret" "s3-credentials" "us-east-1" || exit 1

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"dup-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "A secret named 'dup-secret' already exists"

log_success "Test 15 passed: duplicate-name"
