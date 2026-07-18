#!/bin/bash

# Adds a secret whose name already exists and expects the duplicate-name guard to fire.
# Electron seeds the conflicting secret on the host vault and asserts the file is untouched.
# Mobile seeds via seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 15 "duplicate-name"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    mkdir -p "$TMP_DIR/vault"
    python3 -c "
import json
inner = json.dumps({'region': '', 'accessKeyId': '', 'secretAccessKey': ''})
secret = {'name': 'dup-secret', 'type': 's3-credentials', 'value': inner}
with open('$TMP_DIR/vault/dup-secret.json', 'w') as f:
    json.dump(secret, f)
"
    ORIG_MTIME=$(python3 -c "import os; print(os.path.getmtime('$TMP_DIR/vault/dup-secret.json'))")
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"dup-secret","type":"api-key"},"value":"existing"}]}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"dup-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "A secret named 'dup-secret' already exists"

if [ "$PLATFORM" = "electron" ]; then
    COUNT=$(find "$TMP_DIR/vault" -maxdepth 1 -name "dup-secret*.json" | wc -l)
    if [ "$COUNT" -ne 1 ]; then
        log_error "Expected exactly 1 vault file for 'dup-secret', found $COUNT"
        exit 1
    fi

    NEW_MTIME=$(python3 -c "import os; print(os.path.getmtime('$TMP_DIR/vault/dup-secret.json'))")
    if [ "$ORIG_MTIME" != "$NEW_MTIME" ]; then
        log_error "Original vault file was overwritten by duplicate-add"
        log_error "Original mtime: $ORIG_MTIME, new mtime: $NEW_MTIME"
        exit 1
    fi

    # The expected save error from the duplicate-name throw is allowed; any other [ERROR] is a regression.
    if grep '\[ERROR\]' "$TMP_DIR/app.log" 2>/dev/null \
            | grep -v "Save error:" \
            | grep -v "A secret named 'dup-secret' already exists" \
            | grep -q .; then
        log_error "Unexpected errors in app.log:"
        grep '\[ERROR\]' "$TMP_DIR/app.log" \
            | grep -v "Save error:" \
            | grep -v "A secret named 'dup-secret' already exists" \
            | while IFS= read -r line; do
                echo "  $line"
            done
        exit 1
    fi
    log_success "No unexpected errors in app.log"
fi

log_success "Test 15 passed: duplicate-name"
