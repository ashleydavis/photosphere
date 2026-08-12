#!/bin/bash
DESCRIPTION="psi watch syncs to the origin, then evict-originals drops confirmed originals but keeps thumbnails"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-84}"
print_test_header "$TEST_NUMBER" "WATCH SYNC AND EVICT"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
TEST_DB_DIR="$TEST_DIR/test-db"
ORIGIN_DB_DIR="$TEST_DIR/origin-db"
WATCH_DIR="$TEST_DIR/photos"
RESTORE_DIR="$TEST_DIR/restored"
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

# --evict-budget 0 keeps no local originals at all, which is what makes eviction observable with
# ordinary-sized test photos. The built-in policy's cap is two gigabytes, far more than any smoke
# test is going to import.
WATCH_OUTPUT=""
invoke_command "Watch, sync and evict" "$CLI_COMMAND watch --db $TEST_DB_DIR $WATCH_DIR --once --evict --evict-budget 0 --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "The file was imported"

# --- The asset reached the origin. ---

# The origin's "Files imported" counter stays at zero: that counts what was imported into it
# directly, and nothing was. What matters is that the files are there, so this counts them.
ORIGIN_ASSET_COUNT=$(ls -1 "$ORIGIN_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$ORIGIN_ASSET_COUNT" 1 "The origin holds the original"

ORIGIN_THUMB_COUNT=$(ls -1 "$ORIGIN_DB_DIR/thumb" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$ORIGIN_THUMB_COUNT" 1 "The origin holds the thumbnail"

invoke_command "Verify the origin" "$CLI_COMMAND verify --db $ORIGIN_DB_DIR --yes"

# --- The local original is gone, the thumbnail is not. ---

LOCAL_ASSET_COUNT=$(ls -1 "$TEST_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$LOCAL_ASSET_COUNT" 0 "The local original was dropped"

LOCAL_THUMB_COUNT=$(ls -1 "$TEST_DB_DIR/thumb" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$LOCAL_THUMB_COUNT" 1 "The local thumbnail was kept"

# --- The asset still opens, fetched from the origin on demand. ---

# Exporting reads the original through the local database. The original is not there any more, so a
# successful export is the local database fetching it back from the origin, which is the whole point
# of evicting only what the origin holds.
mkdir -p "$RESTORE_DIR"

# The asset id is the name of the thumbnail file, which eviction leaves in place.
ASSET_ID=$(ls -1 "$TEST_DB_DIR/thumb" | head -1)
if [ -z "$ASSET_ID" ]; then
    log_error "No thumbnail was left behind, so there is no asset id to export"
    exit 1
fi

invoke_command "Export the evicted original from the local database" "$CLI_COMMAND export --db $TEST_DB_DIR $ASSET_ID $RESTORE_DIR/restored.png --type original --yes"

check_exists "$RESTORE_DIR/restored.png" "The exported original"

RESTORED_SIZE=$(wc -c < "$RESTORE_DIR/restored.png" | tr -d ' ')
SOURCE_SIZE=$(wc -c < "$TEST_FILES_DIR/test.png" | tr -d ' ')
expect_value "$RESTORED_SIZE" "$SOURCE_SIZE" "The exported original is the whole file"
log_success "The evicted original was fetched back from the origin"

test_passed
