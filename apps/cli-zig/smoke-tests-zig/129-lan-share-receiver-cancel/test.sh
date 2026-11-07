#!/bin/bash
DESCRIPTION="A waiting receiver exits cleanly on SIGINT"

# A receiver no sender connects to is sent SIGINT, and its log must show no bind error, stack trace
# or panic.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Test: Receiver exits cleanly on cancel ---"

mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

receiver_log="${TEST_TMP_DIR}/receiver-timeout.log"
start_receiver_with_code "secrets" "$receiver_log" "$(allocate_pairing_code)"
log_info "Receiver started (no sender will connect)"

kill -INT "$RECEIVER_PID" 2>/dev/null || true
wait "$RECEIVER_PID" 2>/dev/null || true
RECEIVER_PID=""

if ! grep -q "EADDRINUSE\|stack trace\|panic" "$receiver_log" 2>/dev/null; then
    log_success "Receiver cancel: exited cleanly after SIGINT"
else
    cat "$receiver_log" 2>/dev/null || true
    test_failed "Receiver cancel: log contains errors"
fi

test_passed
