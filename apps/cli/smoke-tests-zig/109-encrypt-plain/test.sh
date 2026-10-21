#!/bin/bash
DESCRIPTION="Encrypt plain DB in place with psi encrypt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_encrypt_plain() {
    local test_number="$1"
    local name="encrypt-plain"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local plain_dir="$test_dir/plain-db"
    local key_name="enc-plain-key"

    mkdir -p "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes"

    ts_verify "$plain_dir"

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$plain_dir"

    invoke_command "Encrypt plain database in place using psi encrypt" "$cli encrypt --db \"$plain_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$plain_dir" --key "$key_name"

    if [ ! -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Encrypted database missing .db/encryption.pub after psi encrypt"
        test_failed "$name"
    fi

    assert_database_assets_encrypted "$plain_dir" || test_failed "$name"

    invoke_command "Verify encrypted database" "$cli verify --db \"$plain_dir\" --key \"$key_name\" --yes"

    test_passed
}

test_encrypt_plain "${1:-109}"
