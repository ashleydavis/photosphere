#!/bin/bash

# Renames an existing secret. Electron seeds the vault on the host and asserts the old
# key is gone / new key holds the value. Mobile seeds via seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 14 "rename-secret"

TMP_DIR="$TEST_DIR/tmp"
RAW_KEY="sk-rename-me"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    mkdir -p "$TMP_DIR/vault"
    RAW_KEY="$RAW_KEY" python3 -c "
import json, os
secret = {'name': 'old-name', 'type': 'api-key', 'value': os.environ['RAW_KEY']}
with open('$TMP_DIR/vault/old-name.json', 'w') as f:
    json.dump(secret, f)
"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"old-name","type":"api-key"},"value":"the-api-key-value"}]}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"new-name"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

if [ "$PLATFORM" = "electron" ]; then
    if [ -f "$TMP_DIR/vault/old-name.json" ]; then
        log_error "Old vault entry $TMP_DIR/vault/old-name.json still exists"
        exit 1
    fi

    if [ ! -f "$TMP_DIR/vault/new-name.json" ]; then
        log_error "New vault entry $TMP_DIR/vault/new-name.json was not created"
        exit 1
    fi

    NEW_VALUE=$(python3 -c "
import json
with open('$TMP_DIR/vault/new-name.json') as f:
    data = json.load(f)
print(data['value'], end='')
")

    if [ "$NEW_VALUE" != "$RAW_KEY" ]; then
        log_error "Renamed entry's value was not preserved"
        log_error "Expected: $RAW_KEY"
        log_error "Actual:   $NEW_VALUE"
        exit 1
    fi
fi

check_no_errors "$TMP_DIR"

log_success "Test 14 passed: rename-secret"
