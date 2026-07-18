#!/bin/bash

# Edits the region of an existing s3-credentials secret. Electron seeds the vault on the
# host and asserts the JSON value has no label and preserves other fields. Mobile seeds
# via seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 13 "edit-s3-credentials"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    mkdir -p "$TMP_DIR/vault"
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
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"s3-cred","type":"s3-credentials"},"value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIAEXAMPLE\",\"secretAccessKey\":\"secretvalue\"}"}]}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-s3-region-input","text":"eu-west-1"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated"

if [ "$PLATFORM" = "electron" ]; then
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
fi

check_no_errors "$TMP_DIR"

log_success "Test 13 passed: edit-s3-credentials"
