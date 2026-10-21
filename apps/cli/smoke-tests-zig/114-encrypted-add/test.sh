#!/bin/bash
DESCRIPTION="Add file to encrypted DB"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_add_encrypted_file() {
    local test_number="$1"
    local name="add-encrypted-file"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key_name="add-enc-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    assert_database_assets_encrypted "$db_dir" || test_failed "$name"

    test_passed
}

test_add_encrypted_file "${1:-114}"
