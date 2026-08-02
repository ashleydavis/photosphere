#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && native_pwd)"

print_test_header 14 "rename-secret"

TMP_DIR="$TEST_DIR/tmp"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/vault"

# Seed the vault with an api-key whose vault key matches its name.
RAW_KEY="sk-rename-me"
write_vault_secret "$TMP_DIR/vault/old-name.json" old-name api-key "$RAW_KEY"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}'
wait_for_log "$TMP_DIR" "Edit secret dialog opened"

# Change the name field.
send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"new-name"}'

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret updated"

# Assert the new vault key holds the value and the old key is gone.
if [ -f "$TMP_DIR/vault/old-name.json" ]; then
    log_error "Old vault entry $TMP_DIR/vault/old-name.json still exists"
    exit 1
fi

if [ ! -f "$TMP_DIR/vault/new-name.json" ]; then
    log_error "New vault entry $TMP_DIR/vault/new-name.json was not created"
    exit 1
fi

NEW_VALUE=$(jq -j '.value' "$TMP_DIR/vault/new-name.json")

if [ "$NEW_VALUE" != "$RAW_KEY" ]; then
    log_error "Renamed entry's value was not preserved"
    log_error "Expected: $RAW_KEY"
    log_error "Actual:   $NEW_VALUE"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 14 passed: rename-secret"
