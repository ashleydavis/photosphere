#!/bin/bash
DESCRIPTION="Zig replicate/verify: Re-encrypt DB with new key (key rotation) (smoke-tests-encrypted.sh encrypt-reencrypt)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_encrypt_reencrypt from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_encrypt_reencrypt() {
    local name="encrypt-reencrypt"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc1_dir="$test_dir/encrypted-db-1"
    local key1_name="reenc-key1"
    local key2_name="reenc-key2"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database with key1" "$cli init --db \"$enc1_dir\" --key \"$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file with key1" "$cli add --db \"$enc1_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Re-encrypt database in place with key2" "$cli encrypt --db \"$enc1_dir\" --key \"$key2_name,$key1_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc1_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify re-encrypted database with key2" "$zig_cli verify --db \"$enc1_dir\" --key \"$key2_name\" --yes" || {
        test_failed "$name"
        return
    }

    # Sanity check: trying to verify with key1 should fail.
    local output
    output=$(eval "$zig_cli verify --db \"$enc1_dir\" --key \"$key1_name\" --yes" 2>&1)
    if [ $? -eq 0 ]; then
        log_error "Verification of re-encrypted database unexpectedly succeeded with old key"
        echo "$output"
        test_failed "$name"
        return
    fi

    test_passed "$name"
}

test_encrypt_reencrypt

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
