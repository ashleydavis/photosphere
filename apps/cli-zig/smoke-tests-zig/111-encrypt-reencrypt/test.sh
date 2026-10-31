#!/bin/bash
DESCRIPTION="Re-encrypt DB with new key (key rotation)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_encrypt_reencrypt() {
    local test_number="$1"
    local name="encrypt-reencrypt"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc1_dir="$test_dir/encrypted-db-1"
    local key1_name="reenc-key1"
    local key2_name="reenc-key2"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database with key1" "$cli init --db \"$enc1_dir\" --key \"$key1_name\" --generate-key --yes"

    verify_database "$enc1_dir" --key "$key1_name"

    invoke_command "Add PNG file with key1" "$cli add --db \"$enc1_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    verify_database "$enc1_dir" --key "$key1_name"

    assert_database_assets_encrypted "$enc1_dir" || test_failed "$name"

    invoke_command "Re-encrypt database in place with key2" "$cli encrypt --db \"$enc1_dir\" --key \"$key2_name,$key1_name\" --generate-key --yes"

    verify_database "$enc1_dir" --key "$key2_name,$key1_name"

    assert_database_assets_encrypted "$enc1_dir" || test_failed "$name"

    invoke_command "Verify re-encrypted database with key2" "$cli verify --db \"$enc1_dir\" --key \"$key2_name\" --yes"

    # Sanity check: trying to verify with key1 should fail.
    local output
    output=$(eval "$cli verify --db \"$enc1_dir\" --key \"$key1_name\" --yes" 2>&1)
    if [ $? -eq 0 ]; then
        log_error "Verification of re-encrypted database unexpectedly succeeded with old key"
        echo "$output"
        test_failed "$name"
    fi

    test_passed
}

test_encrypt_reencrypt "${1:-111}"
