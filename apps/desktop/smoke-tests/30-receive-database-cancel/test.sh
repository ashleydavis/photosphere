#!/bin/bash

# The receiving half of cancellation. A receiver waits for a sender, the user cancels, and then the
# user starts receiving again: the second attempt has to pair and import.
#
# The receive-share task runs under the same fixed LAN_SHARE_SOURCE tag as every other share task, so
# a backend that keeps a cancelled source discards the restarted receive silently, leaving the dialog
# waiting for a sender that has already connected.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
print_test_header 30 "receive-database-cancel"


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

start_app "$TMP_DIR/receiver" 0
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

# --- 1. Wait for a sender that never comes, then cancel. ---

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

send_command "$RECEIVER_PORT" type '{"dataId":"receive-database-code-input","text":"0000"}'
send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}'

# The Cancel button only renders while the dialog is in its waiting step, so its presence is proof
# the receive task is actually running and there is something to cancel.
wait_for_value "$RECEIVER_PORT" "receive-database-cancel-button" "Cancel"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-cancel-button"}'

# Cancelling closes the dialog, so the code input goes with it. Waiting for that keeps the test from
# running ahead and reopening the dialog while the first receive is still in flight.
wait_for_value_gone "$RECEIVER_PORT" "receive-database-cancel-button" "Cancel" || {
    log_error "Receiver is still waiting for a sender after the receive was cancelled"
    exit 1
}
log_success "The cancelled receive stopped and the dialog closed"

# --- 2. Receive again, this time with a real sender. ---

start_app "$TMP_DIR/sender" 960
SENDER_PORT="$APP_PORT"
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/sender" "Databases page loaded"

send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}'

code="$(read_pairing_code "$SENDER_PORT")" || {
    log_error "Sender never displayed a pairing code"
    exit 1
}
log_info "Pairing code: $code"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Database review step"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Database imported"

if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
    log_error "Receiver databases.toml does not contain the database taken by the restarted receive"
    exit 1
fi
log_success "A receive started after a cancelled one paired and imported the database"

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 30 passed: receive-database-cancel"
