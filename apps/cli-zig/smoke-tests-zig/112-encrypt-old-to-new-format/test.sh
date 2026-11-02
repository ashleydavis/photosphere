#!/bin/bash
DESCRIPTION="Encrypt in place with same key (format conversion, no-op)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_encrypt_old_to_new_format() {
    local test_number="$1"
    local name="encrypt-old-to-new-format"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local old_dir="$test_dir/old-encrypted-db"
    local key_name="enc-fmt-key"

    mkdir -p "$test_dir"

    # Encrypt with same key as source: CLI exits early (no rewrite). Database
    # remains encrypted and verifies with that key.

    invoke_command "Init encrypted database (simulated old-format source)" "$cli init --db \"$old_dir\" --key \"$key_name\" --generate-key --yes"

    verify_database "$old_dir" --key "$key_name"

    invoke_command "Add PNG file to simulated old-format database" "$cli add --db \"$old_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    verify_database "$old_dir" --key "$key_name"

    invoke_command "Run psi encrypt in place to convert to new format" "$cli encrypt --db \"$old_dir\" --key \"$key_name\" --yes"

    verify_database "$old_dir" --key "$key_name"

    assert_database_assets_encrypted "$old_dir" || test_failed "$name"

    invoke_command "Verify converted encrypted database" "$cli verify --db \"$old_dir\" --key \"$key_name\" --yes"

    test_passed
}

test_encrypt_old_to_new_format "${1:-112}"
