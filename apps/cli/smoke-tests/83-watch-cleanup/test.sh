#!/bin/bash
DESCRIPTION="psi add --cleanup deletes a source file the database holds, and keeps one it does not"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-83}"
print_test_header "$TEST_NUMBER" "WATCH CLEANUP"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
TEST_DB_DIR="$TEST_DIR/test-db"
WATCH_DIR="$TEST_DIR/photos"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

invoke_command "Initialize database" "$CLI_COMMAND init --db $TEST_DB_DIR --yes"

# --- 1. Without --cleanup the source file is left where it is. ---

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/kept.png"

invoke_command "Import without cleanup" "$CLI_COMMAND add --db $TEST_DB_DIR $WATCH_DIR --yes"
check_exists "$WATCH_DIR/kept.png" "The source file with cleanup off"

# --- 2. With --cleanup the source file goes once the asset is in the database. ---

cp "$TEST_FILES_DIR/test.jpg" "$WATCH_DIR/deleted.jpg"

WATCH_OUTPUT=""
invoke_command "Import with cleanup" "$CLI_COMMAND add --db $TEST_DB_DIR $WATCH_DIR --cleanup --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "The new file was imported"

if [ -e "$WATCH_DIR/deleted.jpg" ]; then
    log_error "The source file was not deleted after the asset was confirmed in the database"
    exit 1
fi
log_success "The imported source file was deleted"

# The file that was already in the database is confirmed just as surely, so it goes too.
if [ -e "$WATCH_DIR/kept.png" ]; then
    log_error "The source file already in the database was not deleted"
    exit 1
fi
log_success "The source file the database already held was deleted"

# Both assets are still in the database: cleanup deletes the source, never the asset.
SUMMARY_OUTPUT=""
invoke_command "Summarize the database" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 2 "Both assets are in the database"

invoke_command "Verify the database" "$CLI_COMMAND verify --db $TEST_DB_DIR --yes"

# --- 3. A file that cannot be imported is not deleted. ---

# A .jpg that is not an image at all: the scanner takes it in on its content type, and the import
# fails when the image tools cannot read it. Nothing about it reaches the database, so deleting it
# would destroy the only copy of whatever it really is.
printf 'this is not an image' > "$WATCH_DIR/broken.jpg"

WATCH_OUTPUT=""
invoke_command "Import with cleanup over a file that cannot be imported" "$CLI_COMMAND add --db $TEST_DB_DIR $WATCH_DIR --cleanup --yes" 1 WATCH_OUTPUT

check_exists "$WATCH_DIR/broken.jpg" "The source file that failed to import"

SUMMARY_OUTPUT=""
invoke_command "Summarize the database again" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 2 "The broken file did not reach the database"

test_passed
