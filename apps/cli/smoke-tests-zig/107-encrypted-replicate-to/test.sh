#!/bin/bash
DESCRIPTION="Replicate plain DB to encrypted destination"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_replicate_to_encrypted() {
    local test_number="$1"
    local name="replicate-to-encrypted"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local src_dir="$test_dir/plain-db"
    local dest_dir="$test_dir/encrypted-db"
    local dest_key_name="rep-to-enc-dest"

    mkdir -p "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$src_dir\" --yes"

    ts_verify "$src_dir"

    invoke_command "Add PNG file to plain database" "$cli add --db \"$src_dir\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$src_dir"

    invoke_command "Replicate to encrypted destination" "$cli replicate --db \"$src_dir\" --dest \"$dest_dir\" --dest-key \"$dest_key_name\" --generate-key --yes"

    ts_verify "$dest_dir" --key "$dest_key_name"

    if [ ! -f "$dest_dir/.db/encryption.pub" ]; then
        log_error "Encrypted destination missing .db/encryption.pub"
        test_failed "$name"
    fi

    assert_database_assets_encrypted "$dest_dir" || test_failed "$name"

    invoke_command "Verify encrypted destination database" "$cli verify --db \"$dest_dir\" --key \"$dest_key_name\" --yes"

    test_passed
}

test_replicate_to_encrypted "${1:-107}"
