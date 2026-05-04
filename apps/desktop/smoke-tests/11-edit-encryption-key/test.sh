#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 11 "edit-encryption-key"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/vault"

# Seed the vault with a raw-PEM encryption-key (no JSON envelope).
# This is the format produced by the Receive-Secret flow that previously
# crashed when the user clicked Edit.
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

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

# Click the Edit button on the only row.
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Save without modification — the round-trip must preserve the raw PEM format.
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

# Assert the vault still contains the raw PEM (not a JSON envelope).
# Compare in Python because bash command substitution strips trailing newlines.
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

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
