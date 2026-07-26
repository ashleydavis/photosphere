#!/bin/bash

# Mobile-only test (step 6b). Proves mobile secrets live in the device keychain, not plaintext
# localStorage: a secret added on the device survives an app restart (loaded back from the keychain),
# and no plaintext copy of it is ever written to WebView localStorage. This is the test that would
# catch a regression back to plaintext localStorage storage.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 39 "secret-in-keychain"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# The default add-secret type is s3-credentials, whose region field is on screen at open and reads
# back through the revealed-secret-region field. A distinctive value so the round-trip is unambiguous.
SECRET_NAME="keychain-secret"
SECRET_REGION="keychain-region-42"

# Reads the localStorage value for a key through the control bridge, echoing the raw value (empty when
# absent). Used to assert no plaintext secret lingers in localStorage.
read_local_storage() {
    local port="$1"
    local key="$2"
    local response
    response=$(curl -sf "http://localhost:$port/get-storage?storageKey=$key" 2>/dev/null || true)
    echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/'
}

# Reads the value of a data-id element through the control bridge (empty when absent/not found).
read_value() {
    local port="$1"
    local data_id="$2"
    local response
    response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
    echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/'
}

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# --- First launch: add the secret, prove it is not in plaintext localStorage. ---

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate (also clears any keychain secret from a previous run so the name is unique).
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"secret-name-input\",\"text\":\"$SECRET_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-s3-region-input\",\"text\":\"$SECRET_REGION\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

# The secret must NOT be in localStorage: neither under the legacy combined-blob key nor under the
# per-secret keychain key names (which belong to the keychain and must never be mirrored to localStorage).
for storage_key in "photosphere.secrets" "photosphere.secret.$SECRET_NAME" "photosphere.secret-type.$SECRET_NAME"; do
    plaintext=$(read_local_storage "$APP_PORT" "$storage_key")
    if [ -n "$plaintext" ]; then
        log_error "A plaintext secret copy is in localStorage under '$storage_key' after add: '$plaintext'"
        exit 1
    fi
done
log_info "No plaintext secret copy in localStorage after add (good)."

check_no_errors "$TMP_DIR"

# --- Restart the app WITHOUT resetting config, so persistence is via the keychain only. ---

stop_app "$APP_PORT" "$TMP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Anchored on the COUNT, not the bare "Secrets page loaded": the page emits that line once when the load
# completes and again when the loaded list reaches it, and the first of those can still show an empty
# list. Waiting for the count means waiting for the secret to actually be on screen. start_app parks the
# log cursor at the end of the previous launch's output, so this can only match the relaunched app.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded: 1 secret"

# The secret entry survived the restart (enumerated from the keychain, nothing was cached across it).
survived_name=$(read_value "$APP_PORT" "secret-row-name-$SECRET_NAME")
if [ "$survived_name" != "$SECRET_NAME" ]; then
    log_error "Secret did not survive restart: expected '$SECRET_NAME', read '$survived_name'"
    exit 1
fi
log_info "Secret entry survived restart."

# Reveal it and confirm the VALUE survived (read from the keychain, not just the entry metadata).
send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"view-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened"
send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed"

revealed_region=$(read_value "$APP_PORT" "revealed-secret-region")
if [ "$revealed_region" != "$SECRET_REGION" ]; then
    log_error "Secret value did not survive restart: expected '$SECRET_REGION', revealed '$revealed_region'"
    exit 1
fi
log_info "Secret value survived restart via the keychain."

# Still no copy in localStorage after the restart, under any of the keys.
for storage_key in "photosphere.secrets" "photosphere.secret.$SECRET_NAME" "photosphere.secret-type.$SECRET_NAME"; do
    plaintext_after=$(read_local_storage "$APP_PORT" "$storage_key")
    if [ -n "$plaintext_after" ]; then
        log_error "A plaintext secret copy appeared in localStorage under '$storage_key' after restart: '$plaintext_after'"
        exit 1
    fi
done
log_info "No plaintext secret copy in localStorage after restart (good)."

check_no_errors "$TMP_DIR"

log_success "Test 39 passed: secret-in-keychain (survives restart, no plaintext in localStorage)"
