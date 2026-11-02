#!/bin/bash
DESCRIPTION="Share a database over LAN between two Zig CLIs"

# A database entry, with its S3 credentials and encryption key, sent by one Zig CLI and received by
# another.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

share_database_and_check

test_passed
