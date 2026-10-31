#!/bin/bash
DESCRIPTION="List files in encrypted DB"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_list_encrypted_files() {
    local test_number="$1"
    local name="list-encrypted-files"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key_name="list-enc-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    verify_database "$db_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    verify_database "$db_dir" --key "$key_name"

    assert_database_assets_encrypted "$db_dir" || test_failed "$name"

    local list_output
    invoke_command "List files in encrypted database" "$cli list --db \"$db_dir\" --key \"$key_name\" --yes" 0 list_output

    if ! echo "$list_output" | grep -q "test.png"; then
        log_error "List output does not reference added asset"
        echo "$list_output"
        test_failed "$name"
    fi

    if ! echo "$list_output" | grep -q "Encryption:"; then
        log_error "List output does not contain Encryption field"
        echo "$list_output"
        test_failed "$name"
    fi

    if ! echo "$list_output" | grep -q "encrypted (key:"; then
        log_error "List output does not show encrypted status with key hash"
        echo "$list_output"
        test_failed "$name"
    fi

    test_passed
}

test_list_encrypted_files "${1:-118}"
