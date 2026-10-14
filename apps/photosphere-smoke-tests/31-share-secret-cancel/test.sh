#!/bin/bash

# Cancelling a secret share, then sharing again. Secrets go over the same LAN-share machinery and the same single LAN_SHARE_SOURCE task
# tag as databases, so this covers the secret half of the same cancel-and-restart behaviour that 29 covers for databases.
#
# The sender is the app under test on every platform. The receiver of the restarted share is a second copy of the app on a desktop. A
# phone cannot run two copies of the app, so on Android and iOS the receiver is the psi CLI on the host.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 31 "share-secret-cancel"

# A host-side receiver can only reach the device's sender over the LAN bridge. Checked before the cleanup trap is armed, so failing here
# does not run a teardown for an app that never started.
require_lan_bridge

trap 'cleanup_apps "$TMP_DIR" "$TMP_DIR/receiver"' EXIT

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
SENDER_PORT="$APP_PORT"
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

# The sender holds one secret, added through the real Add Secret dialog because a phone's vault cannot be written from the host.
add_secret_via_ui "$SENDER_PORT" test-secret api-key "TESTAPIKEY123" || exit 1

# --- 1. Start a share, then cancel it while it waits for a receiver. ---

# The share action is in the row's actions menu on a phone. A desktop has no such menu and the click finds nothing.
send_command "$SENDER_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

first_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the first share"
    exit 1
}
log_info "First pairing code: $first_code"

send_command "$SENDER_PORT" click '{"dataId":"share-secret-cancel-button"}' || exit 1

# The dialog closes on cancel, taking the pairing code with it. A dead app answers nothing, which must not read as a cancelled share,
# so the wait only believes an answer that arrived.
wait_for_pairing_code_gone "$SENDER_PORT" || {
    log_error "Sender is still showing a pairing code after the share was cancelled"
    exit 1
}
log_success "The cancelled share stopped and the dialog closed"

# --- 2. Share again and carry it through to a receiver. ---

send_command "$SENDER_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

second_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the share started after the cancel"
    exit 1
}
log_info "Second pairing code: $second_code"

case "$PLATFORM" in
    ios|android)
        log_info "Receiving the secret on the host CLI..."
        run_zig_cli "$TMP_DIR" secrets receive --yes --code "$second_code" > "$TMP_DIR/receiver.log" 2>&1 || {
            log_error "The CLI receiver failed. Its output: $TMP_DIR/receiver.log"
            exit 1
        }
        RECEIVER_VAULT_DIR="$TMP_DIR/cli-vault"
        ;;
    *)
        mkdir -p "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"
        start_app "$TMP_DIR/receiver"
        RECEIVER_PORT="$APP_PORT"
        wait_for_ready "$RECEIVER_PORT"

        send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

        # The receive action is in the page's actions menu on a phone. A desktop has no such menu and the click finds nothing.
        send_command "$RECEIVER_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"
        wait_for_value "$RECEIVER_PORT" "receive-secret-start-button" "Start"

        send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$second_code\"}" || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secret review step"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Secret saved"
        RECEIVER_VAULT_DIR="$TMP_DIR/receiver/vault"
        ;;
esac

if ! vault_has_secret "$RECEIVER_VAULT_DIR" test-secret; then
    log_error "Receiver vault has no secret from the restarted share"
    exit 1
fi
log_success "A share started after a cancelled one paired and delivered the secret"

check_no_errors "$TMP_DIR"
case "$PLATFORM" in
    ios|android)
        ;;
    *)
        check_no_errors "$TMP_DIR/receiver"
        stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"
        ;;
esac

stop_app "$SENDER_PORT" "$TMP_DIR"

log_success "Test 31 passed: share-secret-cancel"
