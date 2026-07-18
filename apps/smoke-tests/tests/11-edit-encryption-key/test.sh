#!/bin/bash

# Edits an existing encryption-key secret and asserts the raw PEM round-trips.
# Electron seeds the vault on the host filesystem and verifies the file after save.
# Mobile seeds via seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 11 "edit-encryption-key"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    mkdir -p "$TMP_DIR/vault"

    # Seed the vault with a raw-PEM encryption-key (no JSON envelope).
    export RAW_PEM="-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQ
-----END PRIVATE KEY-----
"
    python3 -c "
import json, os
secret = {'name': 'enc-key-1', 'type': 'encryption-key', 'value': os.environ['RAW_PEM']}
with open('$TMP_DIR/vault/enc-key-1.json', 'w') as f:
    json.dump(secret, f)
"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"enc-key","type":"encryption-key"},"value":"-----BEGIN PRIVATE KEY-----\nMOCK\n-----END PRIVATE KEY-----"}]}' || exit 1
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
    # Assert the vault still contains the raw PEM (not a JSON envelope).
    RAW_PEM="$RAW_PEM" python3 -c "
import json, os, sys
with open('$TMP_DIR/vault/enc-key-1.json') as f:
    data = json.load(f)
expected = os.environ['RAW_PEM']
actual = data['value']
if actual != expected:
    print('FAIL: vault value differs from the raw PEM', file=sys.stderr)
    print('Expected (repr):', repr(expected), file=sys.stderr)
    print('Actual   (repr):', repr(actual), file=sys.stderr)
    sys.exit(1)
if data.get('type') != 'encryption-key':
    print('FAIL: type field changed:', data.get('type'), file=sys.stderr)
    sys.exit(1)
" || exit 1
fi

check_no_errors "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
