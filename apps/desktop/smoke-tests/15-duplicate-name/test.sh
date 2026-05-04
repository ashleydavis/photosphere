#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 15 "duplicate-name"

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

# Pre-create a secret with the name "dup-secret".
python3 -c "
import json
inner = json.dumps({'region': '', 'accessKeyId': '', 'secretAccessKey': ''})
secret = {'name': 'dup-secret', 'type': 's3-credentials', 'value': inner}
with open('$TMP_DIR/vault/dup-secret.json', 'w') as f:
    json.dump(secret, f)
"

# Capture the original file's modification timestamp so we can verify
# the duplicate-add does not overwrite it.
ORIG_MTIME=$(python3 -c "import os; print(os.path.getmtime('$TMP_DIR/vault/dup-secret.json'))")

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

# Try to add another secret with the same name.
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"dup-secret"}'
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'

# The save handler should log the duplicate-name error and the file should
# remain untouched. Wait for the error to appear in the log.
wait_for_log "$TMP_DIR" "A secret named 'dup-secret' already exists"

# Assert there is exactly one vault file matching dup-secret*.json.
COUNT=$(find "$TMP_DIR/vault" -maxdepth 1 -name "dup-secret*.json" | wc -l)
if [ "$COUNT" -ne 1 ]; then
    log_error "Expected exactly 1 vault file for 'dup-secret', found $COUNT"
    exit 1
fi

# Assert the original file's modification timestamp is unchanged
# (i.e. the duplicate add did not overwrite it).
NEW_MTIME=$(python3 -c "import os; print(os.path.getmtime('$TMP_DIR/vault/dup-secret.json'))")
if [ "$ORIG_MTIME" != "$NEW_MTIME" ]; then
    log_error "Original vault file was overwritten by duplicate-add"
    log_error "Original mtime: $ORIG_MTIME, new mtime: $NEW_MTIME"
    exit 1
fi

# The expected save error from the duplicate-name throw is allowed; any
# other [ERROR] line is a regression. log.exception emits two lines per
# error (a "Save error:" header and the message itself), so filter both.
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

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 15 passed: duplicate-name"
