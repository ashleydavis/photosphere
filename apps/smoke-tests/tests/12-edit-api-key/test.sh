#!/bin/bash

# Edits an existing api-key secret. Electron seeds the vault on the host and verifies
# the raw key string is preserved. Mobile seeds via seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 12 "edit-api-key"

TMP_DIR="$TEST_DIR/tmp"
RAW_KEY="sk-test-1234567890ABCDEF"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    mkdir -p "$TMP_DIR/vault"
    RAW_KEY="$RAW_KEY" python3 -c "
import json, os
secret = {'name': 'api-key-1', 'type': 'api-key', 'value': os.environ['RAW_KEY']}
with open('$TMP_DIR/vault/api-key-1.json', 'w') as f:
    json.dump(secret, f)
"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"api-key","type":"api-key"},"value":"the-api-key-value"}]}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

if [ "$PLATFORM" = "electron" ]; then
    SAVED_VALUE=$(python3 -c "
import json
with open('$TMP_DIR/vault/api-key-1.json') as f:
    data = json.load(f)
print(data['value'], end='')
")
    if [ "$SAVED_VALUE" != "$RAW_KEY" ]; then
        log_error "Vault value is no longer the raw API key"
        log_error "Expected: $RAW_KEY"
        log_error "Actual:   $SAVED_VALUE"
        exit 1
    fi
fi

check_no_errors "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
