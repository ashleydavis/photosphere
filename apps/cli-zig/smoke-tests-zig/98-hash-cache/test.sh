#!/bin/bash
DESCRIPTION="Every psi hash-cache subcommand, run by the Zig CLI on the hash cache of a real database"

# The hash cache of a database lives under PHOTOSPHERE_CACHE_DIR, which lib/common.sh points at this
# test's own directory. The test fills it through an import and through each writing subcommand,
# and reads it back through each reading one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs a hash-cache subcommand through the Zig CLI and expects the exit code. The output goes into
# the named variable.
#
invoke_hash_cache() {
    local description="$1"
    local hash_cache_arguments="$2"
    local expected_exit_code="$3"
    local output_var_name="$4"

    local zig_cache_output
    invoke_command "$description with the Zig CLI" "$(get_zig_cli_command) -q hash-cache $hash_cache_arguments" "$expected_exit_code" "zig_cache_output"

    eval "$output_var_name=\"\$zig_cache_output\""
}

#
# Prints the one hash cache directory under a cache root, found on disk rather than taken from what
# `hash-cache dir` prints, which is a Windows path on Windows. Fails the test unless there is exactly one.
#
hash_cache_dir_under() {
    local cache_root="$1"

    local found_dirs
    found_dirs="$(find "$cache_root" -type d -name hash-cache)"
    local found_count
    found_count="$(echo "$found_dirs" | grep -c .)"
    if [ "$found_count" != "1" ]; then
        log_error "Expected one hash cache directory under $cache_root, found $found_count: $found_dirs"
        exit 1
    fi
    echo "$found_dirs"
}

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

test_hash_cache() {
    local test_number="$1"
    print_test_header "$test_number" "HASH CACHE"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/hash-cache-db"
    local png_hash
    png_hash="$(sha256_of_file "$TEST_FILES_DIR/test.png")"
    local jpg_hash
    jpg_hash="$(sha256_of_file "$TEST_FILES_DIR/test.jpg")"

    # --- 1. An import records the file it hashed, with the asset id it was given. ---

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    verify_database "$db_dir"
    invoke_command "Add a PNG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    verify_database "$db_dir"
    local asset_id
    asset_id="$(ls "$db_dir/asset")"

    local cache_dir
    invoke_hash_cache "Print the cache directory" "dir --db \"$db_dir\"" 0 "cache_dir"
    expect_output_string "$cache_dir" "[/\\][0-9a-f]\{16\}[/\\]hash-cache$" "The cache is in a directory of the database's own"
    local cache_dir_on_disk
    cache_dir_on_disk="$(hash_cache_dir_under "$PHOTOSPHERE_CACHE_DIR")"
    expect_value "$(basename "$(dirname "$cache_dir_on_disk")")" "$(basename "$(dirname "${cache_dir//\\//}")")" "The printed directory is the one the import wrote"

    local count_output
    invoke_hash_cache "Count the entries" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "1" "The import recorded one entry"

    local png_key
    invoke_hash_cache "List the entries" "list --db \"$db_dir\"" 0 "png_key"
    expect_output_string "$png_key" "test/test.png$" "The entry is keyed by the path of the imported file"

    local get_output
    invoke_hash_cache "Get the hash of the imported file" "get \"$png_key\" --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$png_hash" "The entry holds the file's SHA-256"

    local asset_id_output
    invoke_hash_cache "Get the asset id of the imported file" "get-asset-id \"$png_key\" --db \"$db_dir\"" 0 "asset_id_output"
    expect_value "$asset_id_output" "$asset_id" "The entry holds the id the file was given in the database"

    local show_output
    invoke_command "Show the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 1$" "The cache shows one entry"
    expect_output_string "$show_output" "Keyed by: file path" "The entry is keyed by its path"
    expect_output_string "$show_output" "Hash: $png_hash" "The entry shows its hash"
    expect_output_string "$show_output" "Asset id: $asset_id" "The entry shows its asset id"

    # --- 2. The writing subcommands. ---

    local hash_file_output
    invoke_hash_cache "Hash a file without the cache" "hash-file \"$TEST_FILES_DIR/test.jpg\"" 0 "hash_file_output"
    expect_value "$hash_file_output" "$jpg_hash" "hash-file prints the file's SHA-256"
    invoke_hash_cache "Count the entries after hash-file" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "1" "hash-file adds nothing to the cache"

    local add_output
    invoke_command "Add a JPG file to the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache add \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "add_output"
    expect_value "$add_output" "$jpg_hash" "add prints the hash it recorded"
    invoke_command "Record a hash against a path with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set some/path $png_hash 1317 --db \"$db_dir\""
    invoke_command "Record a hash against a source id with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set-source source-1 $jpg_hash 715 --db \"$db_dir\""

    invoke_hash_cache "Count the entries after the writes" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "4" "The cache holds the imported file and the three written entries"

    local list_output
    invoke_hash_cache "List the entries after the writes" "list --db \"$db_dir\"" 0 "list_output"
    expect_output_string "$list_output" "^$TEST_FILES_DIR/test.jpg$" "The added file is listed under the path it was given"
    expect_output_string "$list_output" "^some/path$" "The path set is listed"
    expect_output_string "$list_output" "^source-1$" "The source id is listed"

    invoke_hash_cache "Get the hash of the added file" "get \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The added file's entry holds its hash"
    invoke_hash_cache "Get the hash set against a path" "get some/path --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$png_hash" "The path's entry holds the hash that was set"
    invoke_hash_cache "Get the hash set against a source id" "get source-1 --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The source id's entry holds the hash that was set"

    invoke_hash_cache "Get the asset id of an entry that has none (should fail)" "get-asset-id some/path --db \"$db_dir\"" 1 "get_output"
    invoke_hash_cache "Get a key that is not cached (should fail)" "get no/such/key --db \"$db_dir\"" 1 "get_output"

    invoke_command "Show the cache after the writes with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 4$" "The cache shows four entries"
    expect_output_string "$show_output" "Keyed by: photo library source id" "The source id's entry is keyed by source id"
    expect_output_string "$show_output" "Asset id: (not known to be in the database)" "The written entries have no asset id"

    # --- 3. remove ---

    invoke_command "Remove the path's entry with the Zig CLI" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\""
    invoke_command "Remove it again with the Zig CLI (should fail)" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\"" 1
    invoke_hash_cache "Get the removed entry (should fail)" "get some/path --db \"$db_dir\"" 1 "get_output"
    invoke_hash_cache "Count the entries after the removal" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "3" "The removal took one entry out"

    # --- 4. clear takes out the hash cache and nothing else of the database's. ---

    local clear_output
    invoke_command "Clear the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache clear --db \"$db_dir\" --yes" 0 "clear_output"
    expect_value "$clear_output" "✓ Cleared hash cache at: $cache_dir" "The cleared cache is named"
    if [ -e "$cache_dir_on_disk" ]; then
        log_error "The hash cache directory $cache_dir_on_disk is still there after it was cleared"
        exit 1
    fi
    log_success "The hash cache directory is gone"
    check_exists "$(dirname "$cache_dir_on_disk")/imports.dat" "The database's import record, which clear leaves alone"

    invoke_hash_cache "Count the entries after the clear" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "0" "The cleared cache holds nothing"
    invoke_command "Show the cleared cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "Local hash cache not found or empty." "The cleared cache shows as empty"

    test_passed
}

test_hash_cache "${1:-98}"
