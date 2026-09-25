#!/bin/bash
DESCRIPTION="Zig replicate/verify: Replicate encrypted DB to plain destination (smoke-tests-encrypted.sh replicate-from-encrypted)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_replicate_from_encrypted from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_replicate_from_encrypted() {
    local name="replicate-from-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local enc_dir="$test_dir/encrypted-db"
    local plain_dir="$test_dir/plain-db"
    local key_name="rep-from-enc-key"

    prepare_test_dir "$test_dir"

    invoke_command "Init encrypted source database" "$cli init --db \"$enc_dir\" --key \"$key_name\" --generate-key --yes" || {
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

    invoke_command "Replicate from encrypted to plain destination" "$zig_cli replicate --db \"$enc_dir\" --dest \"$plain_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    if [ -f "$plain_dir/.db/encryption.pub" ]; then
        log_error "Plain destination should not have .db/encryption.pub"
        test_failed "$name"
        return
    fi

    assert_database_assets_plain "$plain_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify plain destination database" "$zig_cli verify --db \"$plain_dir\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_replicate_from_encrypted

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
