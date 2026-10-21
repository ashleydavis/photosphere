#!/bin/bash
DESCRIPTION="Encrypt plain DB with generated key and ensure key file is created and cleaned up"

# The encrypted suite this came from ran this test twice in a row against one vault, so the second
# run met a vault that already held the key the first run generated. This test does the same: the
# body runs twice against this test's vault, the second time in a second database directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

#
# Creates a plain database with one file in the given directory, encrypts it in place with a
# generated vault key and checks it.
# Usage: encrypt_with_generated_key <name> <plain_dir>
#
encrypt_with_generated_key() {
    local name="$1"
    local plain_dir="$2"

    local cli
    cli="$(get_zig_cli_command)"

    local key_name="enc-gen-key"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes"

    ts_verify "$plain_dir"

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$plain_dir"

    invoke_command "Encrypt plain database with generated vault key" "$cli encrypt --db \"$plain_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$plain_dir" --key "$key_name"

    if [ ! -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Expected encryption.pub not found after encrypt with generated key"
        test_failed "$name"
    fi
}

test_encrypt_generate_key_file() {
    local test_number="$1"
    local name="encrypt-generate-key-file"
    print_test_header "$test_number" "$name"

    local test_dir="$TEST_TMP_DIR/$name"

    mkdir -p "$test_dir"

    log_info "First run: the vault holds no key yet"
    encrypt_with_generated_key "$name" "$test_dir/plain-db"

    log_info "Second run: the vault already holds the key the first run generated"
    encrypt_with_generated_key "$name" "$test_dir/plain-db-2"

    test_passed
}

test_encrypt_generate_key_file "${1:-110}"
