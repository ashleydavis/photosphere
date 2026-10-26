#!/bin/bash

# Cancelling a database share must stop that share and leave the feature usable. The sender shows a pairing code, the user cancels, and
# then shares again: the second share has to pair and deliver just as the first would have.
#
# Every LAN-share task runs under one fixed source tag (LAN_SHARE_SOURCE), and cancelling calls cancelTasks on it. A backend that
# remembers a cancelled source therefore drops the restarted share with no error at all, which is what makes the restart half of this
# test the point of it rather than padding: the cancel on its own passes whether or not the restart is possible.
#
# The sender is the app under test on every platform. The receiver of the restarted share is a second copy of the app on a desktop. A
# phone cannot run two copies of the app, so on Android and iOS the receiver is the psi CLI on the host.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 29 "share-database-cancel"

# A host-side receiver can only reach the device's sender over the LAN bridge. Checked before the cleanup trap is armed, so failing here
# does not run a teardown for an app that never started.
require_lan_bridge

trap 'cleanup_apps "$TMP_DIR" "$TMP_DIR/receiver"' EXIT

"${PLATFORM}_reset_app_state" || exit 1

# The entry is here to be listed and shared, not opened, so nothing creates what it points at. The path is inside this test's own
# directory, because a fixed machine-wide path is a thing two runs of this suite would share.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"test-db\",\"path\":\"$("${PLATFORM}_app_path" "smoke-test-db")\"}]" || exit 1

start_app "$TMP_DIR"
SENDER_PORT="$APP_PORT"
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# --- 1. Start a share, then cancel it while it waits for a receiver. ---

# The share action is in the row's actions menu on a phone. A desktop has no such menu and the click finds nothing.
send_command "$SENDER_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}' || exit 1
# The dialog fills its name, description and path from the entry in an effect after it opens, and the Send button sends what the form
# held when it was last drawn. A click sent straight after the one that opens the dialog lands before the form has been filled, which
# would share a database with no name and no path. Asking the page for the button first gives it the turn it needs.
wait_for_value "$SENDER_PORT" "share-database-send-button" "Send"
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

first_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the first share"
    exit 1
}
log_info "First pairing code: $first_code"

send_command "$SENDER_PORT" click '{"dataId":"share-database-cancel-button"}' || exit 1

# The dialog closes on cancel, taking the pairing code out of the DOM with it. Waiting for that is what makes the cancel observable:
# without it the test would carry straight on and could read the first share's code again, which would pass even if nothing had been
# cancelled.
wait_for_pairing_code_gone "$SENDER_PORT" || {
    log_error "Sender is still showing a pairing code after the share was cancelled"
    exit 1
}
log_success "The cancelled share stopped and the dialog closed"

# --- 2. Share again and carry it through to a receiver. ---

# The receiving app is started and its dialog opened before the share, because the sender waits for a receiver only for a fixed time.
case "$PLATFORM" in
    ios|android)
        ;;
    *)
        mkdir -p "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"
        start_app "$TMP_DIR/receiver"
        RECEIVER_PORT="$APP_PORT"
        wait_for_ready "$RECEIVER_PORT"

        send_command "$RECEIVER_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

        # The receive action is in the page's actions menu on a phone. A desktop has no such menu and the click finds nothing.
        send_command "$RECEIVER_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"
        wait_for_value "$RECEIVER_PORT" "receive-database-start-button" "Start"
        ;;
esac

send_command "$SENDER_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}' || exit 1
# Same wait as the first share, for the same reason.
wait_for_value "$SENDER_PORT" "share-database-send-button" "Send"
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

second_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the share started after the cancel"
    exit 1
}
log_info "Second pairing code: $second_code"

# A code on screen only proves the dialog re-rendered. Pairing with a real receiver is what proves the restarted find-receiver task is
# running, which is the part a remembered cancellation breaks.
case "$PLATFORM" in
    ios|android)
        log_info "Receiving the database on the host CLI..."
        run_cli "$TMP_DIR" dbs receive --yes --code "$second_code" > "$TMP_DIR/receiver.log" 2>&1 || {
            log_error "The CLI receiver failed. Its output: $TMP_DIR/receiver.log"
            exit 1
        }
        if ! run_cli "$TMP_DIR" dbs list | grep -q 'test-db'; then
            log_error "The CLI receiver's database list does not contain the database sent by the restarted share"
            exit 1
        fi
        ;;
    *)
        send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$second_code\"}" || exit 1
        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Database review step"

        send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
        wait_for_log "$TMP_DIR/receiver" "Database imported"

        if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
            log_error "Receiver databases.toml does not contain the database sent by the restarted share"
            exit 1
        fi
        ;;
esac
log_success "A share started after a cancelled one paired and delivered the database"

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

log_success "Test 29 passed: share-database-cancel"
