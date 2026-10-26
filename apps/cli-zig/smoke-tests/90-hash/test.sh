#!/bin/bash
DESCRIPTION="psi hash prints the SHA-256, date and size of a file, a database's own asset file among them"

# This test runs the `hash` command end to end. The hash is checked against the platform's own
# SHA-256 tool rather than against a value written into the test, and every output is compared in
# full with the expected report, whose date is the file's modification time in UTC as `date` reads it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Prints the SHA-256 of a file as hex, with whichever tool the platform has.
#
sha256_of_file() {
    local file_path="$1"

    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$file_path" | cut -d ' ' -f 1
    else
        shasum -a 256 "$file_path" | cut -d ' ' -f 1
    fi
}

#
# Hashes a file with the Zig CLI, checks each line it printed, and checks the whole report.
#
expect_hash_output() {
    local file_path="$1"
    local description="$2"

    local expected_hash
    expected_hash="$(sha256_of_file "$file_path")"
    local expected_size
    expected_size="$(wc -c < "$file_path" | tr -d ' ')"

    local zig_output
    invoke_command "Hash $description with the Zig CLI" "$(get_zig_cli_command) -q hash \"$file_path\"" 0 "zig_output"

    expect_output_string "$zig_output" "^File: $file_path$" "The output names $description"
    expect_output_string "$zig_output" "^Hash: $expected_hash$" "The hash of $description is the SHA-256 of its content"
    expect_output_string "$zig_output" "^Size: $expected_size bytes$" "The size of $description is its length in bytes"
    expect_output_string "$zig_output" "^Date: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}$" "The date of $description is printed to the second"

    local expected_date
    expected_date="$(date -u -r "$file_path" "+%Y-%m-%d %H:%M:%S")"
    local expected_output
    expected_output="$(printf 'File: %s\nHash: %s\nDate: %s\nSize: %s bytes' "$file_path" "$expected_hash" "$expected_date" "$expected_size")"
    expect_value "$zig_output" "$expected_output" "The whole report for $description is as expected"
}

test_hash() {
    local test_number="$1"
    print_test_header "$test_number" "HASH"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/hash-db"

    # --- 1. A file outside any database. ---

    expect_hash_output "$TEST_FILES_DIR/test.png" "a PNG file"

    # --- 2. The asset file a database stored for an import is the imported file, byte for byte. ---

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    verify_database "$db_dir"
    invoke_command "Add a JPG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.jpg\" --yes"
    verify_database "$db_dir"

    local asset_ids
    asset_ids="$(ls "$db_dir/asset")"
    local asset_count
    asset_count="$(echo "$asset_ids" | wc -l | tr -d ' ')"
    expect_value "$asset_count" "1" "The database holds one asset file"

    local asset_path="$db_dir/asset/$asset_ids"
    expect_hash_output "$asset_path" "the database's asset file"

    local source_hash
    source_hash="$(sha256_of_file "$TEST_FILES_DIR/test.jpg")"
    local asset_output
    invoke_command "Hash the asset file again" "$(get_zig_cli_command) -q hash \"$asset_path\"" 0 "asset_output"
    expect_output_string "$asset_output" "^Hash: $source_hash$" "The asset file hashes the same as the file that was added"

    # --- 3. A file that is not there. ---

    local missing_path="$test_dir/no-such-file.png"
    local zig_missing_output
    invoke_command "Hash a missing file with the Zig CLI (should fail)" "$(get_zig_cli_command) -q hash \"$missing_path\"" 1 "zig_missing_output"
    expect_output_string "$zig_missing_output" "File not found: $missing_path" "A missing file is reported as not found"

    expect_value "$zig_missing_output" "File not found: $missing_path" "A missing file is reported in one line and nothing else"

    test_passed
}

test_hash "${1:-90}"
