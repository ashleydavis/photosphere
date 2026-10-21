#!/bin/bash
DESCRIPTION="Remove asset from encrypted DB"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_delete_encrypted_file() {
    local test_number="$1"
    local name="delete-encrypted-file"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key_name="delete-enc-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || test_failed "$name"

    invoke_command "Remove asset from encrypted database" "$cli remove --db \"$db_dir\" --key \"$key_name\" \"$asset_id\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Verify encrypted database after delete" "$cli verify --db \"$db_dir\" --key \"$key_name\" --yes"

    test_passed
}

test_delete_encrypted_file "${1:-117}"
