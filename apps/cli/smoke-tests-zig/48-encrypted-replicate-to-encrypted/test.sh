#!/bin/bash
DESCRIPTION="Zig replicate/verify: Replicate plain DB to encrypted destination (smoke-tests-encrypted.sh replicate-to-encrypted)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_replicate_to_encrypted from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_replicate_to_encrypted() {
    local name="replicate-to-encrypted"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local src_dir="$test_dir/plain-db"
    local dest_dir="$test_dir/encrypted-db"
    local dest_key_name="rep-to-enc-dest"

    prepare_test_dir "$test_dir"

    invoke_command "Init plain source database" "$cli init --db \"$src_dir\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to plain database" "$cli add --db \"$src_dir\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Replicate to encrypted destination" "$zig_cli replicate --db \"$src_dir\" --dest \"$dest_dir\" --dest-key \"$dest_key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    if [ ! -f "$dest_dir/.db/encryption.pub" ]; then
        log_error "Encrypted destination missing .db/encryption.pub"
        test_failed "$name"
        return
    fi

    assert_database_assets_encrypted "$dest_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify encrypted destination database" "$zig_cli verify --db \"$dest_dir\" --key \"$dest_key_name\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_replicate_to_encrypted

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
