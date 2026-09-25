#!/bin/bash
DESCRIPTION="Zig replicate/verify: Verify encrypted DB with key (smoke-tests-encrypted.sh verify-encrypted-db)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_verify_encrypted_db from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_verify_encrypted_db() {
    local name="verify-encrypted-db"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local key_name="verify-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$db_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted database" "$zig_cli verify --db \"$db_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_verify_encrypted_db

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
