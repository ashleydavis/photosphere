#!/bin/bash
DESCRIPTION="psi hash prints the SHA-256, date and size of a file, a database's own asset file among them"

# The Zig counterpart of the TypeScript `hash` command has no TypeScript smoke test to mirror: this
# test runs it end to end through the Zig CLI. The hash is checked against the platform's own
# SHA-256 tool rather than against a value written into the test, and every output is compared with
# what the TypeScript CLI prints for the same file.

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
# Hashes a file with the Zig CLI, checks what it printed, and checks the TypeScript CLI prints the same.
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

    local ts_output
    invoke_command "Hash $description with the TypeScript CLI" "$(get_cli_command) -q hash \"$file_path\"" 0 "ts_output"
    expect_value "$zig_output" "$ts_output" "The Zig CLI prints what the TypeScript CLI prints for $description"
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
    invoke_command "Add a JPG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.jpg\" --yes"

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

    local ts_missing_output
    invoke_command "Hash a missing file with the TypeScript CLI (should fail)" "$(get_cli_command) -q hash \"$missing_path\"" 1 "ts_missing_output"
    expect_value "$zig_missing_output" "$ts_missing_output" "The Zig CLI reports a missing file as the TypeScript CLI does"

    invoke_command "Verify the database with the TypeScript CLI" "$(get_cli_command) verify --db \"$db_dir\" --yes"

    test_passed
}

test_hash "${1:-90}"
