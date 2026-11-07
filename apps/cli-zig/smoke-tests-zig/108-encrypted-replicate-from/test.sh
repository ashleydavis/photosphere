#!/bin/bash
DESCRIPTION="Replicate encrypted DB to plain destination"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_replicate_from_encrypted() {
    local test_number="$1"
    local name="replicate-from-encrypted"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local plain_dir="$test_dir/plain-db"
    local key_name="rep-from-enc-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted source database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes"

    verify_database "$enc_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    verify_database "$enc_dir" --key "$key_name"

    assert_database_assets_encrypted "$enc_dir" || test_failed "$name"

    invoke_command "Replicate from encrypted to plain destination" "$cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key_name\" --yes"

    verify_database "$plain_dir"

    if [ -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Plain destination should not have .db/encryption.pub"
        test_failed "$name"
    fi

    assert_database_assets_plain "$plain_dir" || test_failed "$name"

    invoke_command "Verify plain destination database" "$cli verify --db \"$plain_dir\" --yes"

    test_passed
}

test_replicate_from_encrypted "${1:-108}"
