#!/bin/bash
DESCRIPTION="Decrypt encrypted DB in place"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_decrypt_encrypted() {
    local test_number="$1"
    local name="decrypt-encrypted"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local key_name="decrypt-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes"

    verify_database "$enc_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    verify_database "$enc_dir" --key "$key_name"

    assert_database_assets_encrypted "$enc_dir" || test_failed "$name"

    invoke_command "Decrypt encrypted database in place" "$cli decrypt --db \"$enc_dir\" --key \"$key_name\" --yes"

    verify_database "$enc_dir"

    if [ -f "$enc_dir/.db/encryption.pub" ]; then
        log_error "Decrypted database should not have .db/encryption.pub after decrypt"
        test_failed "$name"
    fi

    assert_database_assets_plain "$enc_dir" || test_failed "$name"

    invoke_command "Verify decrypted plain database" "$cli verify --db \"$enc_dir\" --yes"

    test_passed
}

test_decrypt_encrypted "${1:-113}"
