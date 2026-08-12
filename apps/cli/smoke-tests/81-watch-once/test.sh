#!/bin/bash
DESCRIPTION="psi watch --once imports what is in the watched folder and skips what is already there"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-81}"
print_test_header "$TEST_NUMBER" "WATCH ONCE"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
TEST_DB_DIR="$TEST_DIR/test-db"
WATCH_DIR="$TEST_DIR/photos"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

invoke_command "Initialize database" "$CLI_COMMAND init --db $TEST_DB_DIR --yes"

# --- 1. A file sitting in the watched folder is imported. ---

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/first.png"

WATCH_OUTPUT=""
invoke_command "Watch the folder once" "$CLI_COMMAND watch --db $TEST_DB_DIR $WATCH_DIR --once --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "One file was imported"
expect_output_value "$WATCH_OUTPUT" "Already added:" 0 "Nothing was already in the database"
expect_output_value "$WATCH_OUTPUT" "Files failed:" 0 "Nothing failed"

SUMMARY_OUTPUT=""
invoke_command "Summarize the database" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 1 "The database holds one asset"

# The source file is left alone: nothing asked for cleanup.
check_exists "$WATCH_DIR/first.png" "The source file"

# --- 2. Running again over the same file imports nothing a second time. ---

WATCH_OUTPUT=""
invoke_command "Watch the folder again" "$CLI_COMMAND watch --db $TEST_DB_DIR $WATCH_DIR --once --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 0 "The file was not imported a second time"
expect_output_value "$WATCH_OUTPUT" "Already added:" 1 "The file was recognised as already in the database"

SUMMARY_OUTPUT=""
invoke_command "Summarize the database again" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 1 "The database still holds one asset"

# --- 3. A second file added to the folder is picked up by the next pass. ---

cp "$TEST_FILES_DIR/test.jpg" "$WATCH_DIR/second.jpg"

WATCH_OUTPUT=""
invoke_command "Watch the folder after adding a file" "$CLI_COMMAND watch --db $TEST_DB_DIR $WATCH_DIR --once --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "The new file was imported"
expect_output_value "$WATCH_OUTPUT" "Already added:" 1 "The old file was recognised"

SUMMARY_OUTPUT=""
invoke_command "Summarize the database once more" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 2 "The database holds both assets"

# --- 4. Subfolders are watched too. ---

mkdir -p "$WATCH_DIR/holiday"
cp "$TEST_FILES_DIR/test.webp" "$WATCH_DIR/holiday/third.webp"

WATCH_OUTPUT=""
invoke_command "Watch the folder with a subfolder" "$CLI_COMMAND watch --db $TEST_DB_DIR $WATCH_DIR --once --yes" 0 WATCH_OUTPUT

expect_output_value "$WATCH_OUTPUT" "Files added:" 1 "The file in the subfolder was imported"

SUMMARY_OUTPUT=""
invoke_command "Summarize after the subfolder" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 3 "The database holds all three assets"

test_passed
