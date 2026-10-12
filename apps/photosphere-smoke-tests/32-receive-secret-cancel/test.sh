#!/bin/bash

# Cancelling a secret receive, then receiving again. The secret counterpart of 30.
#
# The receiver is the app under test on every platform. The sender of the second receive is a second copy of the app on a desktop. A
# phone cannot run two copies of the app, so there the sender is the psi CLI on the host, reaching the device over the LAN bridge.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 32 "receive-secret-cancel"

# A host-side sender can only reach the device's receiver over the LAN bridge. Checked before the cleanup trap is armed, so failing here
# does not run a teardown for an app that never started.
require_lan_bridge

trap 'cleanup_apps "$TMP_DIR" "$TMP_DIR/sender"' EXIT

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

#
# Opens the Receive Secret dialog, waits for its code step to have rendered, types the code and presses Start.
# Usage: open_receive_dialog_and_start <code>
#
open_receive_dialog_and_start() {
    local code="$1"
    # The receive action is in the page's actions menu on a phone. A desktop has no such menu and the click finds nothing.
    send_command "$RECEIVER_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Receive secret dialog opened"

    # The dialog logs that it opened before its code step has rendered, so the log line alone is not enough to type into it. The Start
    # button belongs to that step, so waiting for it is what proves the field below exists.
    wait_for_value "$RECEIVER_PORT" "receive-secret-start-button" "Start"

    send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}" || exit 1
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}' || exit 1
}

# --- 1. Wait for a sender that never comes, then cancel. ---

open_receive_dialog_and_start "0000"

# The Cancel button only renders during the waiting step, so its presence proves the receive task is running and there is something to
# cancel.
wait_for_value "$RECEIVER_PORT" "receive-secret-cancel-button" "Cancel"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-cancel-button"}' || exit 1

wait_for_value_gone "$RECEIVER_PORT" "receive-secret-cancel-button" "Cancel" || {
    log_error "Receiver is still waiting for a sender after the receive was cancelled"
    exit 1
}
log_success "The cancelled receive stopped and the dialog closed"

# --- 2. Receive again, this time with a real sender. ---

case "$PLATFORM" in
    android|ios)
        # Drawn per run, never hardcoded: the code is the only thing that tells two concurrent shares apart.
        code="$(allocate_pairing_code)"
        run_cli "$TMP_DIR" secrets add --yes --name test-secret --type api-key --value "TESTAPIKEY123" > "$TMP_DIR/sender-setup.log" 2>&1 || {
            log_error "The CLI could not add the secret to send. Its output: $TMP_DIR/sender-setup.log"
            exit 1
        }
        open_receive_dialog_and_start "$code"

        # The Cancel button only renders once the receive task is waiting for a sender, so the host sends only after it shows.
        wait_for_value "$RECEIVER_PORT" "receive-secret-cancel-button" "Cancel"
        log_info "Sending the secret from the host CLI..."
        cli_send_expect_success "$TMP_DIR" secrets send --yes --name test-secret --code "$code"
        ;;
    *)
        mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config"
        write_vault_secret "$TMP_DIR/sender/vault" test-secret api-key "TESTAPIKEY123"

        start_app "$TMP_DIR/sender"
        SENDER_PORT="$APP_PORT"
        wait_for_ready "$SENDER_PORT"

        send_command "$SENDER_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

        send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}' || exit 1
        send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

        code="$(read_pairing_code "$SENDER_PORT")" || {
            log_error "Sender never displayed a pairing code"
            exit 1
        }
        log_info "Pairing code: $code"

        open_receive_dialog_and_start "$code"
        ;;
esac

wait_for_log "$TMP_DIR" "Secret review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret saved"

# The dialog stays mounted on its success step over the page, so it is closed before the secrets list behind it is read.
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-close-button"}' || exit 1
wait_for_value "$RECEIVER_PORT" "secret-row-name-test-secret" "test-secret"
log_success "A receive started after a cancelled one paired and saved the secret"

check_no_errors "$TMP_DIR"
case "$PLATFORM" in
    android|ios)
        ;;
    *)
        # The desktop's vault is a file the host can read, so the secret is checked in the vault itself as well as in the list.
        if ! vault_has_secret "$TMP_DIR/vault" test-secret; then
            log_error "Receiver vault has no secret from the restarted receive"
            exit 1
        fi
        check_no_errors "$TMP_DIR/sender"
        stop_app "$SENDER_PORT" "$TMP_DIR/sender"
        ;;
esac

stop_app "$RECEIVER_PORT" "$TMP_DIR"

log_success "Test 32 passed: receive-secret-cancel"
