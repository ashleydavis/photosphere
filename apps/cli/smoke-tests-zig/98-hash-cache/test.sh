#!/bin/bash
DESCRIPTION="Every psi hash-cache subcommand, run by the Zig CLI on the hash cache of a real database, read back by the TypeScript CLI"

# The hash cache of a database lives under PHOTOSPHERE_CACHE_DIR, which lib/common.sh points at this
# test's own directory. The test fills it through an import and through each writing subcommand,
# reads it back through each reading one, and has the TypeScript CLI read every state the Zig CLI
# leaves. It then has both CLIs write the same entries into caches of their own, from nothing, and
# expects the two cache files to be byte for byte the same.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs a hash-cache subcommand through the Zig CLI and the TypeScript CLI, expects the exit code of
# both, and expects them to print the same. The Zig CLI's output goes into the named variable.
#
expect_same_hash_cache_output() {
    local description="$1"
    local hash_cache_arguments="$2"
    local expected_exit_code="$3"
    local output_var_name="$4"

    local zig_cache_output
    invoke_command "$description with the Zig CLI" "$(get_zig_cli_command) -q hash-cache $hash_cache_arguments" "$expected_exit_code" "zig_cache_output"
    local ts_cache_output
    invoke_command "$description with the TypeScript CLI" "$(get_cli_command) -q hash-cache $hash_cache_arguments" "$expected_exit_code" "ts_cache_output"
    expect_value "$zig_cache_output" "$ts_cache_output" "$description: the TypeScript CLI reads what the Zig CLI reads"

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
    ts_verify "$db_dir"
    invoke_command "Add a PNG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    ts_verify "$db_dir"
    local asset_id
    asset_id="$(ls "$db_dir/asset")"

    local cache_dir
    expect_same_hash_cache_output "Print the cache directory" "dir --db \"$db_dir\"" 0 "cache_dir"
    expect_output_string "$cache_dir" "[/\\][0-9a-f]\{16\}[/\\]hash-cache$" "The cache is in a directory of the database's own"
    local cache_dir_on_disk
    cache_dir_on_disk="$(hash_cache_dir_under "$PHOTOSPHERE_CACHE_DIR")"
    expect_value "$(basename "$(dirname "$cache_dir_on_disk")")" "$(basename "$(dirname "${cache_dir//\\//}")")" "The printed directory is the one the import wrote"

    local count_output
    expect_same_hash_cache_output "Count the entries" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "1" "The import recorded one entry"

    local png_key
    expect_same_hash_cache_output "List the entries" "list --db \"$db_dir\"" 0 "png_key"
    expect_output_string "$png_key" "test/test.png$" "The entry is keyed by the path of the imported file"

    local get_output
    expect_same_hash_cache_output "Get the hash of the imported file" "get \"$png_key\" --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$png_hash" "The entry holds the file's SHA-256"

    local asset_id_output
    expect_same_hash_cache_output "Get the asset id of the imported file" "get-asset-id \"$png_key\" --db \"$db_dir\"" 0 "asset_id_output"
    expect_value "$asset_id_output" "$asset_id" "The entry holds the id the file was given in the database"

    # show is the one subcommand run by the Zig CLI alone. The TypeScript CLI prints the same report and
    # then does not exit: its process spins at full CPU until it is killed. hashCacheCommand
    # (apps/cli/src/cmd/hash-cache.ts) returns without calling exit(), unlike the commands around it.
    local show_output
    invoke_command "Show the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 1$" "The cache shows one entry"
    expect_output_string "$show_output" "Keyed by: file path" "The entry is keyed by its path"
    expect_output_string "$show_output" "Hash: $png_hash" "The entry shows its hash"
    expect_output_string "$show_output" "Asset id: $asset_id" "The entry shows its asset id"

    # --- 2. The writing subcommands. ---

    local hash_file_output
    expect_same_hash_cache_output "Hash a file without the cache" "hash-file \"$TEST_FILES_DIR/test.jpg\"" 0 "hash_file_output"
    expect_value "$hash_file_output" "$jpg_hash" "hash-file prints the file's SHA-256"
    expect_same_hash_cache_output "Count the entries after hash-file" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "1" "hash-file adds nothing to the cache"

    local add_output
    invoke_command "Add a JPG file to the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache add \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "add_output"
    expect_value "$add_output" "$jpg_hash" "add prints the hash it recorded"
    invoke_command "Record a hash against a path with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set some/path $png_hash 1317 --db \"$db_dir\""
    invoke_command "Record a hash against a source id with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set-source source-1 $jpg_hash 715 --db \"$db_dir\""

    expect_same_hash_cache_output "Count the entries after the writes" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "4" "The cache holds the imported file and the three written entries"

    local list_output
    expect_same_hash_cache_output "List the entries after the writes" "list --db \"$db_dir\"" 0 "list_output"
    expect_output_string "$list_output" "^$TEST_FILES_DIR/test.jpg$" "The added file is listed under the path it was given"
    expect_output_string "$list_output" "^some/path$" "The path set is listed"
    expect_output_string "$list_output" "^source-1$" "The source id is listed"

    expect_same_hash_cache_output "Get the hash of the added file" "get \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The added file's entry holds its hash"
    expect_same_hash_cache_output "Get the hash set against a path" "get some/path --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$png_hash" "The path's entry holds the hash that was set"
    expect_same_hash_cache_output "Get the hash set against a source id" "get source-1 --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The source id's entry holds the hash that was set"

    expect_same_hash_cache_output "Get the asset id of an entry that has none (should fail)" "get-asset-id some/path --db \"$db_dir\"" 1 "get_output"
    expect_same_hash_cache_output "Get a key that is not cached (should fail)" "get no/such/key --db \"$db_dir\"" 1 "get_output"

    invoke_command "Show the cache after the writes with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 4$" "The cache shows four entries"
    expect_output_string "$show_output" "Keyed by: photo library source id" "The source id's entry is keyed by source id"
    expect_output_string "$show_output" "Asset id: (not known to be in the database)" "The written entries have no asset id"

    # --- 3. remove ---

    invoke_command "Remove the path's entry with the Zig CLI" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\""
    invoke_command "Remove it again with the Zig CLI (should fail)" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\"" 1
    expect_same_hash_cache_output "Get the removed entry (should fail)" "get some/path --db \"$db_dir\"" 1 "get_output"
    expect_same_hash_cache_output "Count the entries after the removal" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "3" "The removal took one entry out"

    # --- 4. An entry the TypeScript CLI writes is read by the Zig CLI. ---

    invoke_command "Record a hash with the TypeScript CLI" "$(get_cli_command) -q hash-cache set ts/path $jpg_hash 715 --db \"$db_dir\""
    invoke_command "Get it with the Zig CLI" "$(get_zig_cli_command) -q hash-cache get ts/path --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The Zig CLI reads the entry the TypeScript CLI wrote"

    # --- 5. clear takes out the hash cache and nothing else of the database's. ---

    local clear_output
    invoke_command "Clear the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache clear --db \"$db_dir\" --yes" 0 "clear_output"
    expect_value "$clear_output" "✓ Cleared hash cache at: $cache_dir" "The cleared cache is named"
    if [ -e "$cache_dir_on_disk" ]; then
        log_error "The hash cache directory $cache_dir_on_disk is still there after it was cleared"
        exit 1
    fi
    log_success "The hash cache directory is gone"
    check_exists "$(dirname "$cache_dir_on_disk")/imports.dat" "The database's import record, which clear leaves alone"

    expect_same_hash_cache_output "Count the entries after the clear" "count --db \"$db_dir\"" 0 "count_output"
    expect_value "$count_output" "0" "The cleared cache holds nothing"
    invoke_command "Show the cleared cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "Local hash cache not found or empty." "The cleared cache shows as empty"

    # --- 6. The two CLIs write the same cache file. ---

    local zig_cache_root="$test_dir/zig-cache"
    local ts_cache_root="$test_dir/ts-cache"
    local cli_name
    for cli_name in zig ts; do
        local cli_command
        local cache_root
        if [ "$cli_name" = "zig" ]; then
            cli_command="$(get_zig_cli_command)"
            cache_root="$zig_cache_root"
        else
            cli_command="$(get_cli_command)"
            cache_root="$ts_cache_root"
        fi
        invoke_command "Add a file to an empty cache ($cli_name)" "PHOTOSPHERE_CACHE_DIR=\"$cache_root\" $cli_command -q hash-cache add \"$TEST_FILES_DIR/test.png\" --db \"$db_dir\""
        invoke_command "Record a hash against a path ($cli_name)" "PHOTOSPHERE_CACHE_DIR=\"$cache_root\" $cli_command -q hash-cache set some/path $jpg_hash 715 --db \"$db_dir\""
        invoke_command "Record a hash against a source id ($cli_name)" "PHOTOSPHERE_CACHE_DIR=\"$cache_root\" $cli_command -q hash-cache set-source source-1 $png_hash 1317 --db \"$db_dir\""
    done

    local zig_cache_dir
    zig_cache_dir="$(hash_cache_dir_under "$zig_cache_root")"
    local ts_cache_dir
    ts_cache_dir="$(hash_cache_dir_under "$ts_cache_root")"
    expect_value "${zig_cache_dir#"$zig_cache_root"}" "${ts_cache_dir#"$ts_cache_root"}" "The two CLIs keep the cache in the same directory under their cache roots"

    local zig_cache_files
    zig_cache_files="$(ls "$zig_cache_dir")"
    local ts_cache_files
    ts_cache_files="$(ls "$ts_cache_dir")"
    expect_value "$zig_cache_files" "$ts_cache_files" "The two CLIs name their cache files the same"
    local cache_file_name
    for cache_file_name in $zig_cache_files; do
        if ! cmp "$zig_cache_dir/$cache_file_name" "$ts_cache_dir/$cache_file_name"; then
            log_error "The Zig CLI wrote $cache_file_name differently from the TypeScript CLI"
            exit 1
        fi
        log_success "The Zig CLI wrote $cache_file_name byte for byte as the TypeScript CLI did"
    done

    ts_verify "$db_dir"

    test_passed
}

test_hash_cache "${1:-98}"
