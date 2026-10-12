#!/bin/bash

# Proves mobile secrets live in the device keychain, not plaintext localStorage: a secret added on the device survives an app restart
# (loaded back from the keychain), and no plaintext copy of it is ever written to the web view's localStorage. This is the test that
# would catch a regression back to plaintext localStorage storage.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 66 "secret-in-keychain"

# The default add-secret type is s3-credentials, whose region field is on screen at open and reads back through the revealed-secret-region
# field. A distinctive value so the round-trip is unambiguous.
SECRET_NAME="keychain-secret"
SECRET_REGION="keychain-region-42"

#
# Reads the localStorage value for a key through the test control connection, echoing the raw value (empty when absent). Used to assert
# no plaintext secret lingers in localStorage.
# Usage: read_local_storage <port> <key>
#
read_local_storage() {
    local port="$1"
    local key="$2"
    local answer
    answer="$(control_command "$port" "$(jq -cn --arg storageKey "$key" '{command: "get-storage", storageKey: $storageKey}')")" || return 1
    # An answer that does not say ok is a failure to read, which must not be mistaken for a key that holds nothing.
    if [ "$(printf '%s' "$answer" | jq -r '.ok // empty')" != "true" ]; then
        return 1
    fi
    printf '%s' "$answer" | jq -r '.value // empty'
}

#
# Fails the test when a copy of the secret is in localStorage under any of the keys a regression could use: the legacy combined-blob key
# and the per-secret keychain key names (which belong to the keychain and must never be mirrored to localStorage).
# Usage: require_no_plaintext_copy <when>
#
require_no_plaintext_copy() {
    local moment="$1"
    local storage_key
    local plaintext
    for storage_key in "photosphere.secrets" "photosphere.secret.$SECRET_NAME" "photosphere.secret-type.$SECRET_NAME"; do
        plaintext="$(read_local_storage "$APP_PORT" "$storage_key")" || {
            log_error "localStorage could not be read through the control connection"
            exit 1
        }
        if [ -n "$plaintext" ]; then
            log_error "A plaintext secret copy is in localStorage under '$storage_key' $moment: '$plaintext'"
            exit 1
        fi
    done
    log_info "No plaintext secret copy in localStorage $moment (good)."
}

trap 'cleanup_apps "$TMP_DIR"' EXIT

# --- First launch: add the secret, prove it is not in plaintext localStorage. ---

# Wipe everything the app has stored on the device (its storage, the web view's data and the keychain) so this test starts from a known
# state. Done before launch, with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$SECRET_NAME" '{dataId: "secret-name-input", text: $text}')" || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$SECRET_REGION" '{dataId: "secret-s3-region-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

require_no_plaintext_copy "after add"

check_no_errors "$TMP_DIR"

# --- Restart the app WITHOUT resetting its data, so persistence is via the keychain only. ---

stop_app "$APP_PORT" "$TMP_DIR"
reset_log_cursor "$TMP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Anchored on the COUNT, not the bare "Secrets page loaded": the page emits that line once when the load completes and again when the
# loaded list reaches it, and the first of those can still show an empty list. Waiting for the count means waiting for the secret to
# actually be on screen.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded: 1 secret"

# The secret entry survived the restart (enumerated from the keychain, nothing was cached across it).
survived_name="$(read_value "$APP_PORT" "secret-row-name-$SECRET_NAME")"
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

revealed_region="$(read_value "$APP_PORT" "revealed-secret-region")"
if [ "$revealed_region" != "$SECRET_REGION" ]; then
    log_error "Secret value did not survive restart: expected '$SECRET_REGION', revealed '$revealed_region'"
    exit 1
fi
log_info "Secret value survived restart via the keychain."

# Still no copy in localStorage after the restart, under any of the keys.
require_no_plaintext_copy "after restart"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 66 passed: secret-in-keychain (survives restart, no plaintext in localStorage)"
