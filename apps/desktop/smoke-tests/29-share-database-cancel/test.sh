#!/bin/bash

# Cancelling a database share must stop that share and leave the feature usable. The sender shows a
# pairing code, the user cancels, and then shares again: the second share has to pair and deliver
# just as the first would have.
#
# Every LAN-share task runs under one fixed source tag (LAN_SHARE_SOURCE), and cancelling calls
# cancelTasks on it. A backend that remembers a cancelled source therefore drops the restarted share
# with no error at all, which is what makes the restart half of this test the point of it rather than
# padding: the cancel on its own passes whether or not the restart is possible.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
print_test_header 29 "share-database-cancel"


cleanup() {
    cleanup_apps "$TMP_DIR/sender" "$TMP_DIR/receiver"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

# The path is inside this test's own temporary directory, not a fixed name under /tmp. Nothing
# creates it (the entry is here to be listed and shared, not opened), but a fixed machine-wide path
# is a thing two runs of this suite would share, and this suite now runs more of itself at once.
cat > "$TMP_DIR/sender/config/databases.toml" << EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/smoke-test-db"

EOF

start_app "$TMP_DIR/sender" 0
SENDER_PORT="$APP_PORT"
# The variable name is passed as a second argument so wait_for_ready can write back the port the app
# ends up on. This test drives two instances, so it has to keep each one's port in its own variable.
# When a launch times out, wait_for_ready relaunches the app, which binds a new OS-assigned port.
# Without the name it can only update APP_PORT, leaving the variable below pointing at the instance
# it just killed, and every send_command after that posts to a dead port and fails with curl exit 1.
wait_for_ready "$SENDER_PORT" SENDER_PORT

send_command "$SENDER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/sender" "Databases page loaded"

# --- 1. Start a share, then cancel it while it waits for a receiver. ---

send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}'

first_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the first share"
    exit 1
}
log_info "First pairing code: $first_code"

send_command "$SENDER_PORT" click '{"dataId":"share-database-cancel-button"}'

# The dialog closes on cancel, taking the pairing code out of the DOM with it. Waiting for that is
# what makes the cancel observable: without it the test would carry straight on and could read the
# first share's code again, which would pass even if nothing had been cancelled.
#
# An empty response means the request itself failed, which is not the same as the pairing code having
# gone, and this loop used to treat the two alike: an app that had died read exactly like a cancelled
# share and satisfied the wait. The response is now required to have arrived before its value is
# believed, and still_showing starts at the code the sender was displaying so a run where every
# request failed ends in the failure below rather than in a pass.
#
# The condition is a pattern test rather than the substring test wait_for_value_gone does, so this
# stays a loop of its own: any four digit code means the share is still up, not one particular one.
deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
still_showing="$first_code"
while [ "$SECONDS" -lt "$deadline" ]; do
    response=$(curl -sf "http://localhost:$SENDER_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    if [ -n "$response" ]; then
        still_showing=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -z "$still_showing" ] || ! echo "$still_showing" | grep -qE '^[0-9]{4}$'; then
            break
        fi
    fi
    sleep "$WAIT_POLL_INTERVAL"
done

if [ -n "$still_showing" ] && echo "$still_showing" | grep -qE '^[0-9]{4}$'; then
    log_error "Sender is still showing a pairing code after the share was cancelled"
    exit 1
fi
log_success "The cancelled share stopped and the dialog closed"

# --- 2. Share again and carry it through to a receiver. ---

send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}'

second_code=$(read_pairing_code "$SENDER_PORT") || {
    log_error "Sender never displayed a pairing code for the share started after the cancel"
    exit 1
}
log_info "Second pairing code: $second_code"

# A code on screen only proves the dialog re-rendered. Pairing with a real receiver is what proves
# the restarted find-receiver task is running, which is the part a remembered cancellation breaks.
start_app "$TMP_DIR/receiver" 960
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT" RECEIVER_PORT

send_command "$RECEIVER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$second_code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Database review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Database imported"

if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
    log_error "Receiver databases.toml does not contain the database sent by the restarted share"
    exit 1
fi
log_success "A share started after a cancelled one paired and delivered the database"

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 29 passed: share-database-cancel"
