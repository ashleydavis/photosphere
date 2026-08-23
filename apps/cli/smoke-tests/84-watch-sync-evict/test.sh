#!/bin/bash
DESCRIPTION="psi add imports, and psi sync pushes what it imported to the origin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-84}"
print_test_header "$TEST_NUMBER" "WATCH AND SYNC"

# This used to drive eviction as well, through `psi watch --evict`. There is no --evict flag any
# more: dropping local originals is not something a desktop CLI user wants, and a one-shot sync must
# never silently delete someone's local files. The eviction code path is unchanged and is still what
# the app turns on as a setting; what it no longer has is a CLI switch, so what it has here is its
# unit tests (packages/node-api/src/test/lib/evict-originals.worker.test.ts) rather than this suite.

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
TEST_DB_DIR="$TEST_DIR/test-db"
ORIGIN_DB_DIR="$TEST_DIR/origin-db"
WATCH_DIR="$TEST_DIR/photos"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

invoke_command "Initialize the local database" "$CLI_COMMAND init --db $TEST_DB_DIR --yes"

# The origin is made by replicating the local database rather than by initializing a second one.
# Two databases created independently have different ids and sync refuses them, which is the
# refusal this feature deliberately leaves in place: making them related is what `psi replicate`
# (or `psi connect`, for a remote that already has content) is for.
invoke_command "Replicate the local database to the origin" "$CLI_COMMAND replicate --db $TEST_DB_DIR --dest $ORIGIN_DB_DIR --yes"
invoke_command "Point the local database at the origin" "$CLI_COMMAND set-origin --db $TEST_DB_DIR $ORIGIN_DB_DIR --yes"

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/holiday.png"

WATCH_OUTPUT=""
invoke_command "Import the folder" "$CLI_COMMAND add --db $TEST_DB_DIR $WATCH_DIR --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "The file was imported"

# The two halves of what `psi watch` used to be, run one after the other. Each is separately useful
# and separately testable, which is the point of splitting them.
invoke_command "Sync to the origin" "$CLI_COMMAND sync --db $TEST_DB_DIR --yes"

# --- The asset reached the origin. ---

# The origin's "Files imported" counter stays at zero: that counts what was imported into it
# directly, and nothing was. What matters is that the files are there, so this counts them.
ORIGIN_ASSET_COUNT=$(ls -1 "$ORIGIN_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$ORIGIN_ASSET_COUNT" 1 "The origin holds the original"

ORIGIN_THUMB_COUNT=$(ls -1 "$ORIGIN_DB_DIR/thumb" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$ORIGIN_THUMB_COUNT" 1 "The origin holds the thumbnail"

invoke_command "Verify the origin" "$CLI_COMMAND verify --db $ORIGIN_DB_DIR --yes"

# --- The local database still holds everything: nothing here deletes local originals. ---

LOCAL_ASSET_COUNT=$(ls -1 "$TEST_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$LOCAL_ASSET_COUNT" 1 "The local original was kept"

invoke_command "Verify the local database" "$CLI_COMMAND verify --db $TEST_DB_DIR --yes"

test_passed
