#!/bin/bash
DESCRIPTION="Zig replicate/verify: Encrypt plain DB in place with psi encrypt (smoke-tests-encrypted.sh encrypt-plain)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_encrypt_plain from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_encrypt_plain() {
    local name="encrypt-plain"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local plain_dir="$test_dir/plain-db"
    local key_name="enc-plain-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$plain_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Encrypt plain database in place using psi encrypt" "$cli encrypt --db \"$plain_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Encrypted database missing .db/encryption.pub after psi encrypt"
        test_failed "$name"
        return
    fi

    assert_database_assets_encrypted "$plain_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database" "$zig_cli verify --db \"$plain_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_encrypt_plain

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
