#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 13 "edit-s3-credentials"

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

# Seed the vault with an s3-credentials secret stored as a JSON value
# containing only the credential fields (no `label`). Edit a field via
# the UI, save, and assert the value is still JSON with no `label`.
python3 -c "
import json
inner = json.dumps({
    'region': 'us-east-1',
    'accessKeyId': 'AKIAOLD',
    'secretAccessKey': 'OLDSECRET'
})
secret = {'name': 's3-creds-1', 'type': 's3-credentials', 'value': inner}
with open('$TMP_DIR/vault/s3-creds-1.json', 'w') as f:
    json.dump(secret, f)
"

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Edit the region field.
send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"eu-west-1"}'

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

# Assert the vault contains JSON with the four credential fields and no `label`.
python3 -c "
import json, sys
with open('$TMP_DIR/vault/s3-creds-1.json') as f:
    saved = json.load(f)
inner = json.loads(saved['value'])
if 'label' in inner:
    print('FAIL: vault value still contains a label key', file=sys.stderr)
    sys.exit(1)
if inner.get('region') != 'eu-west-1':
    print('FAIL: region was not updated, got:', inner.get('region'), file=sys.stderr)
    sys.exit(1)
if inner.get('accessKeyId') != 'AKIAOLD' or inner.get('secretAccessKey') != 'OLDSECRET':
    print('FAIL: other s3 fields were not preserved:', inner, file=sys.stderr)
    sys.exit(1)
" || exit 1

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 13 passed: edit-s3-credentials"
