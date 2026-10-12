#!/bin/bash

# The receiving half of cancellation. A receiver waits for a sender, the user cancels, and then the user starts receiving again: the
# second attempt has to pair and import.
#
# Every LAN-share task runs under one fixed source tag (LAN_SHARE_SOURCE), and cancelling calls cancelTasks on it. A backend that keeps a
# cancelled source discards the restarted receive silently, leaving the dialog waiting for a sender that has already connected. On a
# phone the engine pool once did exactly that: the second receive was dropped before it ran, with no error and no log line, while the
# host CLI sent to nobody.
#
# On a desktop the second receive is paired with a second copy of the app as the sender. A phone cannot run two copies of the app, so
# there the sender is the psi CLI on the host, reaching the device over the LAN bridge.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 30 "receive-database-cancel"

case "$PLATFORM" in
    android|ios)
        # Drawn per run, never hardcoded: the code is the only thing that tells two concurrent shares apart.
        PAIRING_CODE="$(allocate_pairing_code)"

        # A host-side sender can only reach the device's receiver over the LAN bridge. Checked before the stop_app trap is armed, so
        # failing here does not run a teardown for an app that never started.
        require_lan_bridge

        RECEIVER_DIR="$TMP_DIR"
        trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

        log_info "Seeding the host CLI with the database to send..."
        run_cli "$TMP_DIR" secrets add --yes --name received-geo-key --type api-key --value received-geo-value >/dev/null 2>&1
        run_cli "$TMP_DIR" dbs add --yes --name received-db --description "Received over LAN" --path "$TMP_DIR/received-db" --geocoding-key received-geo-key >/dev/null 2>&1

        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        RECEIVER_DIR="$TMP_DIR/receiver"
        trap 'cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"' EXIT

        mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

        # The path is inside this test's own temporary directory. Nothing creates it (the entry is here to be listed and shared, not
        # opened), but a fixed machine-wide path is a thing two runs of this suite would share.
        cat > "$TMP_DIR/sender/config/databases.toml" << TOML
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/smoke-test-db"

TOML
        ;;
esac

start_app "$RECEIVER_DIR"
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$RECEIVER_DIR" "Databases page loaded"

#
# Opens the Receive Database dialog (from the page-actions menu on a phone, where it is a secondary action), waits for its code step to
# have rendered, types the code and presses Start.
# Usage: open_receive_dialog_and_start <code>
#
open_receive_dialog_and_start() {
    local code="$1"
    case "$PLATFORM" in
        android|ios)
            send_command "$RECEIVER_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
            ;;
    esac
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}' || exit 1
    wait_for_log "$RECEIVER_DIR" "Receive database dialog opened"

    # The dialog logs that it opened before its code step has rendered, so the log line alone is not enough to type into it. The Start
    # button belongs to that step, so waiting for it is what proves the field below exists. Without this the type and the click both
    # find nothing, do nothing and say so only in a warning, and the failure surfaces much later as the sender finding no device at
    # all. The reopen after the cancel is where this was seen to lose the race.
    wait_for_value "$RECEIVER_PORT" "receive-database-start-button" "Start"

    send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}" || exit 1
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1
}

# --- 1. Wait for a sender that never comes, then cancel. ---

case "$PLATFORM" in
    android|ios)
        open_receive_dialog_and_start "$PAIRING_CODE"
        ;;
    *)
        open_receive_dialog_and_start "0000"
        ;;
esac

# The Cancel button only renders while the dialog is in its waiting step, so its presence is proof the receive task is actually running
# and there is something to cancel.
wait_for_value "$RECEIVER_PORT" "receive-database-cancel-button" "Cancel"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-cancel-button"}' || exit 1

# Cancelling closes the dialog, so the button goes with it. Waiting for that keeps the test from reopening the dialog while the first
# receive is still in flight, which would prove nothing about the restart. The wait only believes an answer that arrived, so a dead app
# does not read as a cancelled dialog.
wait_for_value_gone "$RECEIVER_PORT" "receive-database-cancel-button" "Cancel" || {
    log_error "Receiver is still waiting for a sender after the receive was cancelled"
    exit 1
}
log_success "The cancelled receive stopped and the dialog closed"

# --- 2. Receive again, this time with a real sender. ---

case "$PLATFORM" in
    android|ios)
        open_receive_dialog_and_start "$PAIRING_CODE"

        # Give the receiver a moment to begin broadcasting, then send from the host with the real CLI.
        sleep 3
        log_info "Sending the database from the host CLI..."
        cli_send_expect_success "$TMP_DIR" dbs send --yes --name received-db --code "$PAIRING_CODE"
        ;;
    *)
        start_app "$TMP_DIR/sender"
        SENDER_PORT="$APP_PORT"
        wait_for_ready "$SENDER_PORT"

        send_command "$SENDER_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR/sender" "Databases page loaded"

        send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}' || exit 1
        # The dialog fills its name, description and path from the entry in an effect after it opens, and the Send button sends what the form
        # held when it was last drawn. A click sent straight after the one that opens the dialog lands before the form has been filled, which
        # would share a database with no name and no path. Asking the page for the button first gives it the turn it needs.
        wait_for_value "$SENDER_PORT" "share-database-send-button" "Send"
        send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

        code="$(read_pairing_code "$SENDER_PORT")" || {
            log_error "Sender never displayed a pairing code"
            exit 1
        }
        log_info "Pairing code: $code"

        open_receive_dialog_and_start "$code"
        ;;
esac

wait_for_log "$RECEIVER_DIR" "Database review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$RECEIVER_DIR" "Database imported"

case "$PLATFORM" in
    android|ios)
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1
        wait_for_value "$RECEIVER_PORT" "database-row-name-received-db" "received-db"
        ;;
    *)
        if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
            log_error "Receiver databases.toml does not contain the database taken by the restarted receive"
            exit 1
        fi
        ;;
esac
log_success "A receive started after a cancelled one paired and imported the database"

case "$PLATFORM" in
    android|ios)
        check_no_errors "$TMP_DIR"
        ;;
    *)
        check_no_errors "$TMP_DIR/sender"
        check_no_errors "$TMP_DIR/receiver"

        stop_app "$SENDER_PORT" "$TMP_DIR/sender"
        stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"
        ;;
esac

log_success "Test 30 passed: receive-database-cancel"
