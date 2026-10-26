#!/bin/bash
DESCRIPTION="Every psi hash-cache subcommand, run by the Zig CLI on the hash cache of a real database, with every output checked against the text expected of it"

# The hash cache of a database lives under PHOTOSPHERE_CACHE_DIR, which lib/common.sh points at this
# test's own directory. The test fills it through an import and through each writing subcommand,
# reads it back through each reading one, and checks what every reading subcommand prints against
# the exact text expected of that state. It then writes a set of entries into a cache of its own,
# from nothing, and expects the cache file to be byte for byte the file expected of those entries.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs a hash-cache subcommand through the Zig CLI, expects its exit code, and expects it to print
# the expected text. The output goes into the named variable.
#
expect_hash_cache_output() {
    local description="$1"
    local hash_cache_arguments="$2"
    local expected_exit_code="$3"
    local expected_output="$4"
    local output_var_name="$5"

    local zig_cache_output
    invoke_command "$description" "$(get_zig_cli_command) -q hash-cache $hash_cache_arguments" "$expected_exit_code" "zig_cache_output"
    expect_value "$zig_cache_output" "$expected_output" "$description: the output is the expected text"

    eval "$output_var_name=\"\$zig_cache_output\""
}

#
# Prints a path in the form the CLI, a native program, sees it: a Windows path on Windows, where the
# shell's own paths are POSIX ones, and the path unchanged everywhere else.
#
native_path() {
    local shell_path="$1"

    if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
        cygpath -w "$shell_path"
    else
        printf '%s' "$shell_path"
    fi
}

#
# Prints the key the hash cache records an imported file under: the file's absolute path with
# backslashes made forward slashes and any leading slash taken off.
#
import_cache_key() {
    local file_path="$1"

    local absolute_path
    absolute_path="$(native_path "$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")")"
    absolute_path="${absolute_path//\\//}"
    printf '%s' "${absolute_path#/}"
}

#
# Prints a file's modification time in whole milliseconds since the epoch, which is what the hash
# cache records of a file it hashed. GNU stat (Linux and Windows) and BSD stat (macOS) are asked in
# their own syntax.
#
file_mtime_milliseconds() {
    local file_path="$1"

    local mtime_seconds
    if ! mtime_seconds="$(stat -c '%.3Y' "$file_path" 2> /dev/null)"; then
        mtime_seconds="$(stat -f '%.3Fm' "$file_path")"
    fi
    local whole_seconds="${mtime_seconds%.*}"
    local fraction="${mtime_seconds#*.}"
    echo $((whole_seconds * 1000 + 10#$fraction))
}

#
# Prints a number as the given count of bytes of little endian hex.
#
little_endian_hex() {
    local number="$1"
    local byte_count="$2"

    local byte_index
    for ((byte_index = 0; byte_index < byte_count; byte_index++)); do
        printf '%02x' $((number & 255))
        number=$((number >> 8))
    done
}

#
# Writes the bytes a string of hex stands for to stdout.
#
write_hex_bytes() {
    local hex_text="$1"

    local hex_index
    for ((hex_index = 0; hex_index < ${#hex_text}; hex_index += 2)); do
        printf "\\x${hex_text:hex_index:2}"
    done
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

    local cache_dir_on_disk
    cache_dir_on_disk="$(hash_cache_dir_under "$PHOTOSPHERE_CACHE_DIR")"
    local database_cache_id
    database_cache_id="$(basename "$(dirname "$cache_dir_on_disk")")"
    local cache_dir
    # The CLI prints the directory resolved, with runs of slashes collapsed. macOS's TMPDIR ends in a
    # slash, so PHOTOSPHERE_CACHE_DIR holds "T//photosphere-tests", and expecting it as it stands failed
    # "Print the cache directory" in the macOS arm64 release run, which printed "T/photosphere-tests".
    local resolved_cache_dir
    resolved_cache_dir="$(printf '%s' "$PHOTOSPHERE_CACHE_DIR/$database_cache_id/hash-cache" | tr -s '/')"
    expect_hash_cache_output "Print the cache directory" "dir --db \"$db_dir\"" 0 "$(native_path "$resolved_cache_dir")" "cache_dir"
    expect_output_string "$cache_dir" "[/\\][0-9a-f]\{16\}[/\\]hash-cache$" "The cache is in a directory of the database's own"
    expect_value "$(basename "$(dirname "$cache_dir_on_disk")")" "$(basename "$(dirname "${cache_dir//\\//}")")" "The printed directory is the one the import wrote"

    local count_output
    expect_hash_cache_output "Count the entries" "count --db \"$db_dir\"" 0 "1" "count_output"
    expect_value "$count_output" "1" "The import recorded one entry"

    local png_key
    expect_hash_cache_output "List the entries" "list --db \"$db_dir\"" 0 "$(import_cache_key "$TEST_FILES_DIR/test.png")" "png_key"
    expect_output_string "$png_key" "test/test.png$" "The entry is keyed by the path of the imported file"

    local get_output
    expect_hash_cache_output "Get the hash of the imported file" "get \"$png_key\" --db \"$db_dir\"" 0 "$png_hash" "get_output"
    expect_value "$get_output" "$png_hash" "The entry holds the file's SHA-256"

    local asset_id_output
    expect_hash_cache_output "Get the asset id of the imported file" "get-asset-id \"$png_key\" --db \"$db_dir\"" 0 "$asset_id" "asset_id_output"
    expect_value "$asset_id_output" "$asset_id" "The entry holds the id the file was given in the database"

    local show_output
    invoke_command "Show the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 1$" "The cache shows one entry"
    expect_output_string "$show_output" "Keyed by: file path" "The entry is keyed by its path"
    expect_output_string "$show_output" "Hash: $png_hash" "The entry shows its hash"
    expect_output_string "$show_output" "Asset id: $asset_id" "The entry shows its asset id"

    # --- 2. The writing subcommands. ---

    local hash_file_output
    expect_hash_cache_output "Hash a file without the cache" "hash-file \"$TEST_FILES_DIR/test.jpg\"" 0 "$jpg_hash" "hash_file_output"
    expect_value "$hash_file_output" "$jpg_hash" "hash-file prints the file's SHA-256"
    expect_hash_cache_output "Count the entries after hash-file" "count --db \"$db_dir\"" 0 "1" "count_output"
    expect_value "$count_output" "1" "hash-file adds nothing to the cache"

    local add_output
    invoke_command "Add a JPG file to the cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache add \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "add_output"
    expect_value "$add_output" "$jpg_hash" "add prints the hash it recorded"
    invoke_command "Record a hash against a path with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set some/path $png_hash 1317 --db \"$db_dir\""
    invoke_command "Record a hash against a source id with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set-source source-1 $jpg_hash 715 --db \"$db_dir\""

    expect_hash_cache_output "Count the entries after the writes" "count --db \"$db_dir\"" 0 "4" "count_output"
    expect_value "$count_output" "4" "The cache holds the imported file and the three written entries"

    # The cache lists its keys in the order it keeps them: the added file's relative path first,
    # since punctuation sorts before letters, then the letter keys compared without regard to case.
    # Where the imported file's key goes among those depends on the checkout's path, so it is put in
    # its place by its lowercase form, which orders it as the cache does for any path that does not
    # differ from "some/path" or "source-1" first at a character other than a letter, a digit, a
    # slash or a dot.
    local lowercase_png_key
    lowercase_png_key="$(printf '%s' "$png_key" | tr '[:upper:]' '[:lower:]')"
    local expected_list="$TEST_FILES_DIR/test.jpg"
    if (export LC_ALL=C; [[ "$lowercase_png_key" < "some/path" ]]); then
        expected_list="$expected_list"$'\n'"$png_key"$'\n'"some/path"$'\n'"source-1"
    elif (export LC_ALL=C; [[ "$lowercase_png_key" < "source-1" ]]); then
        expected_list="$expected_list"$'\n'"some/path"$'\n'"$png_key"$'\n'"source-1"
    else
        expected_list="$expected_list"$'\n'"some/path"$'\n'"source-1"$'\n'"$png_key"
    fi
    local list_output
    expect_hash_cache_output "List the entries after the writes" "list --db \"$db_dir\"" 0 "$expected_list" "list_output"
    expect_output_string "$list_output" "^$TEST_FILES_DIR/test.jpg$" "The added file is listed under the path it was given"
    expect_output_string "$list_output" "^some/path$" "The path set is listed"
    expect_output_string "$list_output" "^source-1$" "The source id is listed"

    expect_hash_cache_output "Get the hash of the added file" "get \"$TEST_FILES_DIR/test.jpg\" --db \"$db_dir\"" 0 "$jpg_hash" "get_output"
    expect_value "$get_output" "$jpg_hash" "The added file's entry holds its hash"
    expect_hash_cache_output "Get the hash set against a path" "get some/path --db \"$db_dir\"" 0 "$png_hash" "get_output"
    expect_value "$get_output" "$png_hash" "The path's entry holds the hash that was set"
    expect_hash_cache_output "Get the hash set against a source id" "get source-1 --db \"$db_dir\"" 0 "$jpg_hash" "get_output"
    expect_value "$get_output" "$jpg_hash" "The source id's entry holds the hash that was set"

    expect_hash_cache_output "Get the asset id of an entry that has none (should fail)" "get-asset-id some/path --db \"$db_dir\"" 1 "" "get_output"
    expect_hash_cache_output "Get a key that is not cached (should fail)" "get no/such/key --db \"$db_dir\"" 1 "" "get_output"

    invoke_command "Show the cache after the writes with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "^Entries: 4$" "The cache shows four entries"
    expect_output_string "$show_output" "Keyed by: photo library source id" "The source id's entry is keyed by source id"
    expect_output_string "$show_output" "Asset id: (not known to be in the database)" "The written entries have no asset id"

    # --- 3. remove ---

    invoke_command "Remove the path's entry with the Zig CLI" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\""
    invoke_command "Remove it again with the Zig CLI (should fail)" "$(get_zig_cli_command) -q hash-cache remove some/path --db \"$db_dir\"" 1
    expect_hash_cache_output "Get the removed entry (should fail)" "get some/path --db \"$db_dir\"" 1 "" "get_output"
    expect_hash_cache_output "Count the entries after the removal" "count --db \"$db_dir\"" 0 "3" "count_output"
    expect_value "$count_output" "3" "The removal took one entry out"

    # --- 4. An entry written after a removal is read back. ---

    invoke_command "Record a hash against another path with the Zig CLI" "$(get_zig_cli_command) -q hash-cache set another/path $jpg_hash 715 --db \"$db_dir\""
    invoke_command "Get it with the Zig CLI" "$(get_zig_cli_command) -q hash-cache get another/path --db \"$db_dir\"" 0 "get_output"
    expect_value "$get_output" "$jpg_hash" "The Zig CLI reads back the entry it wrote"

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

    expect_hash_cache_output "Count the entries after the clear" "count --db \"$db_dir\"" 0 "0" "count_output"
    expect_value "$count_output" "0" "The cleared cache holds nothing"
    invoke_command "Show the cleared cache with the Zig CLI" "$(get_zig_cli_command) -q hash-cache show --db \"$db_dir\" --yes" 0 "show_output"
    expect_output_string "$show_output" "Local hash cache not found or empty." "The cleared cache shows as empty"

    # --- 6. A cache written from nothing is the exact file expected of its entries. ---

    local zig_cache_root="$test_dir/zig-cache"
    invoke_command "Add a file to an empty cache" "PHOTOSPHERE_CACHE_DIR=\"$zig_cache_root\" $(get_zig_cli_command) -q hash-cache add \"$TEST_FILES_DIR/test.png\" --db \"$db_dir\""
    invoke_command "Record a hash against a path" "PHOTOSPHERE_CACHE_DIR=\"$zig_cache_root\" $(get_zig_cli_command) -q hash-cache set some/path $jpg_hash 715 --db \"$db_dir\""
    invoke_command "Record a hash against a source id" "PHOTOSPHERE_CACHE_DIR=\"$zig_cache_root\" $(get_zig_cli_command) -q hash-cache set-source source-1 $png_hash 1317 --db \"$db_dir\""

    local zig_cache_dir
    zig_cache_dir="$(hash_cache_dir_under "$zig_cache_root")"
    expect_value "${zig_cache_dir#"$zig_cache_root"}" "/$database_cache_id/hash-cache" "The cache is kept in the database's own directory under the cache root"

    local zig_cache_files
    zig_cache_files="$(ls "$zig_cache_dir")"
    expect_value "$zig_cache_files" "hash-cache-x.dat" "The cache is one file"

    # The file expected of the three entries: the format version (2) and the entry count (3), then
    # each entry in key order as its key length, key, hash, size and modification time in
    # milliseconds (both 48 bit), 36 bytes of asset id (zero for none) and whether it is keyed by
    # source id. Every number is little endian. The only value not fixed here is the modification
    # time of test.png, which is read from the file. A SHA-256 of all of that ends the file.
    local png_mtime_hex
    png_mtime_hex="$(little_endian_hex "$(file_mtime_milliseconds "$TEST_FILES_DIR/test.png")" 6)"
    local no_asset_id_hex="000000000000000000000000000000000000000000000000000000000000000000000000"
    local expected_body_hex="0200000003000000"
    expected_body_hex+="13000000""2e2e2f2e2e2f746573742f746573742e706e67""$png_hash""250500000000""$png_mtime_hex""$no_asset_id_hex""00"
    expected_body_hex+="09000000""736f6d652f70617468""$jpg_hash""cb0200000000""000000000000""$no_asset_id_hex""00"
    expected_body_hex+="08000000""736f757263652d31""$png_hash""250500000000""000000000000""$no_asset_id_hex""01"
    local expected_cache_file="$test_dir/expected-hash-cache-x.dat"
    write_hex_bytes "$expected_body_hex" > "$expected_cache_file"
    local expected_checksum
    expected_checksum="$(sha256_of_file "$expected_cache_file")"
    write_hex_bytes "$expected_checksum" >> "$expected_cache_file"

    if ! cmp "$zig_cache_dir/hash-cache-x.dat" "$expected_cache_file"; then
        log_error "The Zig CLI wrote hash-cache-x.dat differently from the file expected of its entries"
        exit 1
    fi
    log_success "The Zig CLI wrote hash-cache-x.dat byte for byte as expected"

    test_passed
}

test_hash_cache "${1:-98}"
