#!/bin/bash
DESCRIPTION="psi origin, set-origin, root-hash and database-id, and a sync that finds its destination through the origin"

# The replicate tests read origin, root-hash and database-id in passing; this test runs the four
# commands for what they report and what they write, and checks each value they print against the
# value expected of the databases the Zig CLI wrote.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs a command through the Zig CLI and expects it to print the expected value. The output goes into
# the named variable.
#
expect_printed_value() {
    local description="$1"
    local arguments="$2"
    local expected_value="$3"
    local output_var_name="$4"

    local zig_value
    invoke_command "$description" "$(get_zig_cli_command) -q $arguments" 0 "zig_value"
    expect_value "$zig_value" "$expected_value" "$description: the printed value is the expected one"

    eval "$output_var_name=\"\$zig_value\""
}

test_origin() {
    local test_number="$1"
    print_test_header "$test_number" "ORIGIN, SET-ORIGIN, ROOT-HASH AND DATABASE-ID"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/origin-db"
    local copy_dir="$test_dir/origin-copy"

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    verify_database "$db_dir"

    # --- database-id ---

    local database_id
    expect_printed_value "Get the database id" "database-id --db \"$db_dir\" --yes" "5c724a85-6b64-4e6a-9e15-dfa0821821e1" "database_id"
    expect_output_string "$database_id" "^[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}$" "The database id is a UUID"

    # --- origin, before one is set ---

    local origin_output
    expect_printed_value "Get the origin of a new database" "origin --db \"$db_dir\" --yes" "(not set)" "origin_output"
    expect_value "$origin_output" "(not set)" "A new database has no origin"

    # --- root-hash ---

    local empty_hash
    expect_printed_value "Get the root hash of the empty database" "root-hash --db \"$db_dir\" --yes" "94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7" "empty_hash"
    expect_output_string "$empty_hash" "^[0-9a-f]\{64\}$" "The root hash is a SHA-256"

    invoke_command "Add a PNG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    verify_database "$db_dir"

    local one_file_hash
    invoke_command "Get the root hash after an import" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "one_file_hash"
    expect_output_string "$one_file_hash" "^[0-9a-f]\{64\}$" "The root hash after an import is a SHA-256"
    if [ "$one_file_hash" = "$empty_hash" ]; then
        log_error "The root hash did not change when a file was added: $one_file_hash"
        exit 1
    fi
    log_success "The root hash changed when a file was added"

    # --- A copy shares the database id and the root hash, and records where it came from. ---

    invoke_command "Replicate the database" "$(get_zig_cli_command) replicate --db \"$db_dir\" --dest \"$copy_dir\" --yes"
    verify_database "$copy_dir"

    local copy_id
    expect_printed_value "Get the database id of the copy" "database-id --db \"$copy_dir\" --yes" "5c724a85-6b64-4e6a-9e15-dfa0821821e1" "copy_id"
    expect_value "$copy_id" "$database_id" "The copy has the database id of the database it came from"

    local copy_hash
    expect_printed_value "Get the root hash of the copy" "root-hash --db \"$copy_dir\" --yes" "$one_file_hash" "copy_hash"
    expect_value "$copy_hash" "$one_file_hash" "The copy has the root hash of the database it came from"

    local copy_origin
    expect_printed_value "Get the origin of the copy" "origin --db \"$copy_dir\" --yes" "$(jq -r '.origin' "$copy_dir/.db/config.json" | tr -d '\r')" "copy_origin"
    expect_output_string "$copy_origin" "origin-db$" "The copy's origin is the database it came from"

    # --- set-origin ---

    local set_output
    invoke_command "Set the database's origin to the copy" "$(get_zig_cli_command) -q set-origin --db \"$db_dir\" \"$copy_dir\" --yes" 0 "set_output"
    verify_database "$db_dir"

    local config_origin
    config_origin="$(jq -r '.origin' "$db_dir/.db/config.json")"
    expect_output_string "$config_origin" "origin-copy$" "set-origin writes the origin into .db/config.json"

    expect_printed_value "Get the origin that was set" "origin --db \"$db_dir\" --yes" "$config_origin" "origin_output"
    expect_value "$origin_output" "$config_origin" "origin prints the origin that was set"

    # The origin is what a sync goes to when it is given no destination.
    invoke_command "Add a JPG file to the database" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.jpg\" --yes"
    verify_database "$db_dir"
    invoke_command "Sync the database with no destination" "$(get_zig_cli_command) sync --db \"$db_dir\" --yes"
    verify_database "$db_dir"
    verify_database "$copy_dir"

    local synced_hash
    invoke_command "Get the root hash of the database after the sync" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "synced_hash"
    expect_output_string "$synced_hash" "^[0-9a-f]\{64\}$" "The root hash after the sync is a SHA-256"
    local synced_copy_hash
    expect_printed_value "Get the root hash of the copy after the sync" "root-hash --db \"$copy_dir\" --yes" "$synced_hash" "synced_copy_hash"
    expect_value "$synced_copy_hash" "$synced_hash" "The sync went to the origin, which now matches the database"

    # --- Clearing the origin. ---

    invoke_command "Clear the database's origin" "$(get_zig_cli_command) -q set-origin --db \"$db_dir\" \"\" --yes"
    verify_database "$db_dir"
    expect_printed_value "Get the origin after clearing it" "origin --db \"$db_dir\" --yes" "(not set)" "origin_output"
    expect_value "$origin_output" "(not set)" "A cleared origin is not set"

    test_passed
}

test_origin "${1:-100}"
