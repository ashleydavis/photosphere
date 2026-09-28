#!/bin/bash
DESCRIPTION="psi consolidate creates a remote, joins an unrelated one, and leaves sync working"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-85}"
print_test_header "$TEST_NUMBER" "CONNECT"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
CLI_COMMAND=$(get_zig_cli_command)

# --- 1. Connecting to a path with nothing at it creates the remote. ---

NEW_LOCAL="$TEST_DIR/new-local"
NEW_REMOTE="$TEST_DIR/new-remote"

invoke_command "Initialize a database" "$(get_zig_cli_command) init --db $NEW_LOCAL --yes"
invoke_command "Add a photo" "$(get_zig_cli_command) add --db $NEW_LOCAL $TEST_FILES_DIR/test.png --yes"

invoke_command "Consolidate into a remote that does not exist yet" "$(get_zig_cli_command) consolidate --db $NEW_LOCAL $NEW_REMOTE --yes"

check_exists "$NEW_REMOTE/.db/files.dat" "The created remote database"
NEW_REMOTE_ASSETS=$(ls -1 "$NEW_REMOTE/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$NEW_REMOTE_ASSETS" 1 "The created remote holds the photo"

# Sync works straight away, because replication carried the database id across.
invoke_command "Sync to the created remote" "$(get_zig_cli_command) sync --db $NEW_LOCAL --yes"

# --- 2. Connecting again just records the origin, because the two are already related. ---

invoke_command "Consolidate again into the same remote" "$(get_zig_cli_command) consolidate --db $NEW_LOCAL $NEW_REMOTE --yes"

NEW_REMOTE_ASSETS=$(ls -1 "$NEW_REMOTE/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$NEW_REMOTE_ASSETS" 1 "Connecting again did not duplicate anything"

# --- 3. Connecting to an unrelated remote consolidates the two. ---

LOCAL_DB="$TEST_DIR/local-db"
REMOTE_DB="$TEST_DIR/remote-db"

invoke_command "Initialize the local database" "$(get_zig_cli_command) init --db $LOCAL_DB --yes"
invoke_command "Initialize an unrelated remote database" "$(get_zig_cli_command) init --db $REMOTE_DB --yes"

# The same photo goes into both, so consolidation has something it must not duplicate. Each of them
# also has a photo of its own.
invoke_command "Add the shared photo locally" "$(get_zig_cli_command) add --db $LOCAL_DB $TEST_FILES_DIR/test.png --yes"
invoke_command "Add the shared photo remotely" "$(get_zig_cli_command) add --db $REMOTE_DB $TEST_FILES_DIR/test.png --yes"
invoke_command "Add a local-only photo" "$(get_zig_cli_command) add --db $LOCAL_DB $TEST_FILES_DIR/test.jpg --yes"
invoke_command "Add a remote-only photo" "$(get_zig_cli_command) add --db $REMOTE_DB $TEST_FILES_DIR/test.webp --yes"

# Sync refuses these two, and must keep refusing them until they have been consolidated.
invoke_command "Sync refuses two unrelated databases" "$(get_zig_cli_command) sync --db $LOCAL_DB --dest $REMOTE_DB --yes" 1

CONNECT_OUTPUT=""
invoke_command "Consolidate into the unrelated remote" "$(get_zig_cli_command) consolidate --db $LOCAL_DB $REMOTE_DB --yes" 0 CONNECT_OUTPUT

expect_output_value "$CONNECT_OUTPUT" "Assets pushed to the remote:" 1 "Only the local-only photo was pushed"
expect_output_value "$CONNECT_OUTPUT" "Assets the remote already had:" 1 "The shared photo was recognised and not pushed"

# The remote now holds three originals: its own two plus the one pushed. The shared photo is there
# once, not twice.
REMOTE_ASSETS=$(ls -1 "$REMOTE_DB/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$REMOTE_ASSETS" 3 "The remote holds three originals"

invoke_command "Verify the remote" "$(get_zig_cli_command) verify --db $REMOTE_DB --yes"

# --- 4. Ordinary sync works now, where it refused before. ---

invoke_command "Sync after consolidation" "$(get_zig_cli_command) sync --db $LOCAL_DB --yes"

LOCAL_LIST=""
invoke_command "List the local database" "$CLI_COMMAND list --db $LOCAL_DB --yes" 0 LOCAL_LIST

expect_output_string "$LOCAL_LIST" "test.jpg" "The local-only photo is still here"
expect_output_string "$LOCAL_LIST" "test.webp" "The remote-only photo arrived"
expect_output_string "$LOCAL_LIST" "test.png" "The shared photo is here"

# The shared photo appears once, not twice: consolidation dropped the local duplicate in favour of
# the remote's copy, and sync brought that one back.
SHARED_COUNT=$(echo "$LOCAL_LIST" | grep -c "test.png")
expect_value "$SHARED_COUNT" 1 "The shared photo appears once, not twice"

invoke_command "Verify the remote with the TypeScript CLI" "$(get_cli_command) verify --db $REMOTE_DB --yes"

test_passed
