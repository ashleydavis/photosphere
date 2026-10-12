#!/bin/bash

# Proves the LAN-share timeout window is honoured on the device: with no receiver on the network the share flow must keep searching for
# its full 60 second window before it reports failure. A search that gave up early would leave a user who is still reading the pairing
# code out to the other device with no way to be found, and a search that never gave up would leave the dialog spinning.
#
# This drives the real user path: it adds a secret, opens the share dialog and presses Send, exactly as test 7 does, then times how long
# the dialog takes to report "No receiver found".

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 65 "lan-share-timeout"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's localStorage and the keychain) so this test
# starts from a known state. Done before launch, with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Add a secret so the Secrets page has a row with a Share button to click.

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"timeout-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret added"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

# The pairing code appears the moment the search starts, so it marks the beginning of the 60s window.
log_info "Waiting for the pairing code that marks the start of the search..."
code="$(read_pairing_code "$APP_PORT" 20)" || {
    log_error "Share flow never started searching (no pairing code shown)"
    exit 1
}

start_seconds=$(date +%s)
log_info "Search started with pairing code $code. Waiting for it to give up..."

# No receiver is on the network, so the dialog must eventually show its error alert. Poll well past the 60s window so a correct run is
# never cut short by the poll loop itself.
message=""
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
    message="$(read_value "$APP_PORT" share-error-message)"
    if [ -n "$message" ]; then
        break
    fi
    sleep 1
done

elapsed=$(( $(date +%s) - start_seconds ))

if [ -z "$message" ]; then
    log_error "Share dialog never reported a result after ${elapsed}s (the search did not give up)"
    exit 1
fi

# It must fail because no receiver was found, not for an unrelated reason (e.g. an unreadable secret).
if ! echo "$message" | grep -q "No receiver found"; then
    log_error "Share failed for the wrong reason: $message"
    exit 1
fi

log_info "Search gave up after ${elapsed}s (expected close to 60s)."

# Anything below 50s means the search gave up well before its window ended.
if [ "$elapsed" -lt 50 ]; then
    log_error "LAN-share window collapsed to ${elapsed}s (< 50s): the search gave up before its 60 second window ended."
    exit 1
fi

check_no_errors "$TMP_DIR"

log_success "Test 65 passed: lan-share-timeout (the 60s window lasts a real ~60s on device)"
