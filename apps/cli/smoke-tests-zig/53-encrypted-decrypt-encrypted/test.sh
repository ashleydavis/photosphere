#!/bin/bash
DESCRIPTION="Zig replicate/verify: Decrypt encrypted DB in place (smoke-tests-encrypted.sh decrypt-encrypted)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_decrypt_encrypted from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_decrypt_encrypted() {
    local name="decrypt-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local key_name="decrypt-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$enc_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Decrypt encrypted database in place" "$cli decrypt --db \"$enc_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    if [ -f "$enc_dir/.db/encryption.pub" ]; then
        log_error "Decrypted database should not have .db/encryption.pub after decrypt"
        test_failed "$name"
        return
    fi

    assert_database_assets_plain "$enc_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify decrypted plain database" "$zig_cli verify --db \"$enc_dir\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_decrypt_encrypted

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
