#!/bin/bash
DESCRIPTION="Share a secret over LAN from the Zig CLI to the TypeScript CLI"

# The secret share of test 126, with the TypeScript CLI as the receiver.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Interop: Zig CLI sends a secret, TypeScript CLI receives ---"
RECEIVER_CLI_CMD="$TS_CLI_CMD"
share_secret_and_check

test_passed
