#!/bin/bash

# Cancelling a receive on the device, then receiving again for real. The mobile counterpart of
# desktop 30, and the test that pins the engine pool's cancellation behaviour.
#
# Every LAN-share task on the device runs under one fixed source tag, and cancelling calls cancelTasks
# on it. The mobile engine pool used to remember a cancelled source for the life of the app, so the
# second receive below was dropped before it ran: no error, no log line, the dialog just sat there
# while the host CLI sent to nobody. The pool now re-arms a source when a task is queued from the
# WebView, and this is what proves it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 44 "receive-database-cancel"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# A host-side sender can only reach the device's receiver over the LAN bridge. Checked before the
# stop_app trap is armed, so failing here does not run a teardown for an app that never started.
require_lan_bridge

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

log_info "Seeding the host CLI with the database to send..."
run_cli "$TMP_DIR" secrets add --yes --name received-geo-key --type api-key --value received-geo-value >/dev/null 2>&1
run_cli "$TMP_DIR" dbs add --yes --name received-db --description "Received over LAN" --path "$TMP_DIR/received-db" --geocoding-key received-geo-key >/dev/null 2>&1

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# --- 1. Start receiving, then cancel before any sender appears. ---

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Receive database dialog opened"

send_command "$APP_PORT" type '{"dataId":"receive-database-code-input","text":"4321"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1

# The Cancel button only renders while the dialog is waiting for a sender, so its presence is proof
# the receive task is running and there is something real to cancel.
wait_for_value "$APP_PORT" "receive-database-cancel-button" "Cancel"

send_command "$APP_PORT" click '{"dataId":"receive-database-cancel-button"}' || exit 1

# Cancelling closes the dialog. Waiting for the button to go keeps the test from reopening the dialog
# while the first receive is still in flight, which would prove nothing about the restart.
elapsed=0
still_waiting="Cancel"
while [ "$elapsed" -lt 15 ]; do
    still_waiting=$(read_value "$APP_PORT" "receive-database-cancel-button")
    if [ "$still_waiting" != "Cancel" ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ "$still_waiting" = "Cancel" ]; then
    log_error "The device is still waiting for a sender after the receive was cancelled"
    exit 1
fi
log_success "The cancelled receive stopped and the dialog closed"

# --- 2. Receive again, this time with the real host CLI sending. ---

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Receive database dialog opened"

send_command "$APP_PORT" type '{"dataId":"receive-database-code-input","text":"4321"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1

# Give the receiver a moment to begin broadcasting, then send from the host with the real CLI.
sleep 3
log_info "Sending the database from the host CLI..."
cli_send_expect_success "$TMP_DIR" dbs send --yes --name received-db --code 4321

wait_for_log "$TMP_DIR" "Database review step"

send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database imported"

send_command "$APP_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1

wait_for_value "$APP_PORT" "database-row-name-received-db" "received-db"
log_success "A receive started after a cancelled one took the database from a real sender"

check_no_errors "$TMP_DIR"

log_success "Test 44 passed: receive-database-cancel"
