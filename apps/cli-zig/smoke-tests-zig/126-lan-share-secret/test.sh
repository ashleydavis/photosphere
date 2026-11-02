#!/bin/bash
DESCRIPTION="Share a secret over LAN between two Zig CLIs"

# A secret sent by one Zig CLI and received by another.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

share_secret_and_check

test_passed
