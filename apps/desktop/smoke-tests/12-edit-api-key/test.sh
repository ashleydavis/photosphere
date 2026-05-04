#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 12 "edit-api-key"

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

# Seed the vault with a raw api-key (no JSON envelope), edit it via the
# UI and verify the round-trip preserves the raw-string format.
RAW_KEY="sk-test-1234567890ABCDEF"
RAW_KEY="$RAW_KEY" python3 -c "
import json, os
secret = {'name': 'api-key-1', 'type': 'api-key', 'value': os.environ['RAW_KEY']}
with open('$TMP_DIR/vault/api-key-1.json', 'w') as f:
    json.dump(secret, f)
"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

# Click the Edit button on the only row.
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Save without modification — the round-trip must preserve the raw key string.
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

# Assert the vault still contains the raw key string (not a JSON envelope).
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

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 12 passed: edit-api-key"
