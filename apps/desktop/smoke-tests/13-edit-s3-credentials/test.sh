#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && native_pwd)"

print_test_header 13 "edit-s3-credentials"

TMP_DIR="$TEST_DIR/tmp"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/vault"

# Seed the vault with an s3-credentials secret stored as a JSON value
# containing only the credential fields (no `label`). Edit a field via
# the UI, save, and assert the value is still JSON with no `label`.
write_vault_secret "$TMP_DIR/vault/s3-creds-1.json" s3-creds-1 s3-credentials \
    '{"region":"us-east-1","accessKeyId":"AKIAOLD","secretAccessKey":"OLDSECRET"}'

start_app "$TMP_DIR"
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
# The secret's value is itself a JSON document, so it is read out to its own file and then read
# field by field, rather than parsed twice in one go. `jq -j` writes the string value raw and adds no
# trailing newline, so the file holds exactly the bytes the app stored.
jq -j '.value' "$TMP_DIR/vault/s3-creds-1.json" > "$TMP_DIR/credentials.json"

# `has` is false when the key is absent, which is what "no label key" means here, and jq -e exits
# non-zero on a false result.
if jq -e 'has("label")' "$TMP_DIR/credentials.json" > /dev/null 2>&1; then
    log_error "Vault value still contains a label key"
    exit 1
fi

SAVED_REGION=$(jq -j '.region' "$TMP_DIR/credentials.json")
if [ "$SAVED_REGION" != "eu-west-1" ]; then
    log_error "Region was not updated, got: $SAVED_REGION"
    exit 1
fi

SAVED_ACCESS_KEY=$(jq -j '.accessKeyId' "$TMP_DIR/credentials.json")
SAVED_SECRET_KEY=$(jq -j '.secretAccessKey' "$TMP_DIR/credentials.json")
if [ "$SAVED_ACCESS_KEY" != "AKIAOLD" ] || [ "$SAVED_SECRET_KEY" != "OLDSECRET" ]; then
    log_error "Other s3 fields were not preserved: accessKeyId=$SAVED_ACCESS_KEY secretAccessKey=$SAVED_SECRET_KEY"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 13 passed: edit-s3-credentials"
