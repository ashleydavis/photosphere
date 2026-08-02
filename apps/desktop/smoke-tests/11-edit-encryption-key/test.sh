#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && native_pwd)"

print_test_header 11 "edit-encryption-key"

TMP_DIR="$TEST_DIR/tmp"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
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
printf '%s' "$RAW_PEM" > "$TMP_DIR/raw.pem"
write_vault_secret_from_file "$TMP_DIR/vault/enc-key-1.json" \
    enc-key-1 encryption-key "$TMP_DIR/raw.pem"

start_app "$TMP_DIR"
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
# Compared with cmp against a file, not as a shell string, because command substitution strips
# trailing newlines and the PEM's trailing newline is exactly what this checks survived the round trip.
#
# -b keeps jq's output in binary mode. On Windows jq writes stdout in text mode by default, which
# turns each of the PEM's newlines into CRLF on the way into this file and makes the comparison
# below fail even when the value round-tripped perfectly. The flag is accepted and does nothing on
# Linux and macOS, where output is already byte-exact.
jq -jb '.value' "$TMP_DIR/vault/enc-key-1.json" > "$TMP_DIR/saved.pem"
if ! cmp -s "$TMP_DIR/raw.pem" "$TMP_DIR/saved.pem"; then
    log_error "Vault value differs from the raw PEM"
    exit 1
fi

SAVED_TYPE=$(jq -j '.type' "$TMP_DIR/vault/enc-key-1.json")
if [ "$SAVED_TYPE" != "encryption-key" ]; then
    log_error "Type field changed: $SAVED_TYPE"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
