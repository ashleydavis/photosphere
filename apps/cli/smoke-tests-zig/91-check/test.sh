#!/bin/bash
DESCRIPTION="psi check reports which files a database already holds and changes nothing in it"

# The add tests run `check` only to read its "Already added" count; this test checks everything the
# command reports, for a mix of added and new files, that it leaves the database exactly as it was,
# and that the TypeScript CLI reports the same for the same database.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_check() {
    local test_number="$1"
    print_test_header "$test_number" "CHECK"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/check-db"

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    ts_verify "$db_dir"
    invoke_command "Add a PNG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    ts_verify "$db_dir"

    local hash_before
    invoke_command "Get the root hash before checking" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "hash_before"

    # --- 1. One file that was added and two that were not. ---

    local check_output
    invoke_command "Check an added file and two new ones with the Zig CLI" "$(get_zig_cli_command) -q check --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" \"$TEST_FILES_DIR/test.webp\" --yes" 0 "check_output"

    expect_output_string "$check_output" "Checked 3 files." "The check counts the three files it was given"
    expect_output_value "$check_output" "Files considered:" "3" "Three files were considered"
    expect_output_value "$check_output" "Already added:" "1" "The PNG file is already in the database"
    expect_output_value "$check_output" "Files to add:" "2" "The JPG and WebP files are still to be added"
    expect_output_value "$check_output" "Files failed:" "0" "No file failed"

    local ts_check_output
    invoke_command "Check the same files with the TypeScript CLI" "$(get_cli_command) -q check --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" \"$TEST_FILES_DIR/test.webp\" --yes" 0 "ts_check_output"
    expect_value "$check_output" "$ts_check_output" "The Zig CLI reports what the TypeScript CLI reports"

    # --- 2. A directory: every media file in it is looked at. ---

    local directory_output
    invoke_command "Check a directory with the Zig CLI" "$(get_zig_cli_command) -q check --db \"$db_dir\" \"$DUPLICATE_IMAGES_DIR\" --yes" 0 "directory_output"
    expect_output_value "$directory_output" "Files considered:" "2" "Both files of the directory were considered"
    expect_output_value "$directory_output" "Files to add:" "2" "Neither file of the directory is in the database"

    local ts_directory_output
    invoke_command "Check the directory with the TypeScript CLI" "$(get_cli_command) -q check --db \"$db_dir\" \"$DUPLICATE_IMAGES_DIR\" --yes" 0 "ts_directory_output"
    expect_value "$directory_output" "$ts_directory_output" "The Zig CLI reports the directory as the TypeScript CLI does"

    # --- 3. Checking wrote nothing. ---

    local hash_after
    invoke_command "Get the root hash after checking" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "hash_after"
    expect_value "$hash_after" "$hash_before" "Checking left the database unchanged"

    local summary_output
    invoke_command "Summarize the database" "$(get_zig_cli_command) -q summary --db \"$db_dir\" --yes" 0 "summary_output"
    expect_output_value "$summary_output" "Files imported:" "1" "The database still holds only the one file that was added"

    test_passed
}

test_check "${1:-91}"
