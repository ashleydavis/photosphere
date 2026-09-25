#!/bin/bash
DESCRIPTION="Zig replicate/verify: Encrypt in place with same key (format conversion, no-op) (smoke-tests-encrypted.sh encrypt-old-to-new-format)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/encrypted-functions.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

# Zig version of test_encrypt_old_to_new_format from smoke-tests-encrypted.sh: psi verify and psi replicate run in the Zig CLI.
test_encrypt_old_to_new_format() {
    local name="encrypt-old-to-new-format"
    print_test_header "$name"

    local cli
    cli="$(get_cli_command)"

    local zig_cli
    zig_cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local old_dir="$test_dir/old-encrypted-db"
    local key_name="enc-fmt-key"

    prepare_test_dir "$test_dir"

    # Encrypt with same key as source: CLI exits early (no rewrite). Database
    # remains encrypted and verifies with that key.

    invoke_command "Init encrypted database (simulated old-format source)" "$cli init --db \"$old_dir\" --key \"$key_name\" --generate-key --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Add PNG file to simulated old-format database" "$cli add --db \"$old_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" || {
        test_failed "$name"
        return
    }

    invoke_command "Run psi encrypt in place to convert to new format" "$cli encrypt --db \"$old_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    assert_database_assets_encrypted "$old_dir" || {
        test_failed "$name"
        return
    }

    invoke_command "Verify converted encrypted database" "$zig_cli verify --db \"$old_dir\" --key \"$key_name\" --yes" || {
        test_failed "$name"
        return
    }

    test_passed "$name"
}

test_encrypt_old_to_new_format

# A failed test is recorded by test_failed rather than exiting, as in smoke-tests-encrypted.sh.
if [ $TESTS_FAILED -ne 0 ]; then
    exit 1
fi
