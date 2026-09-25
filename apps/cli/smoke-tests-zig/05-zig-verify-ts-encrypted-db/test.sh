#!/bin/bash
DESCRIPTION="Zig CLI verifies an encrypted database created by the TypeScript CLI"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../smoke-tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

test_zig_verify_ts_encrypted_db() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG VERIFY OF A TYPESCRIPT ENCRYPTED DATABASE"

    local test_dir=$(get_test_dir "$test_number")
    local db_dir="$test_dir/encrypted-db"
    local key_name="zig-verify-ts-enc-key"
    local ts_cli="$(get_ts_cli_command)"
    local zig_cli="$(get_zig_cli_command)"

    check_exists "$zig_cli" "Zig CLI binary"

    # Create an encrypted database with the TypeScript CLI.
    invoke_command "Initialize encrypted database with TypeScript" "$ts_cli init --db $db_dir --key $key_name --generate-key --yes"
    invoke_command "Add PNG file with TypeScript" "$ts_cli add --db $db_dir --key $key_name $TEST_FILES_DIR/test.png --yes"
    invoke_command "Add JPG file with TypeScript" "$ts_cli add --db $db_dir --key $key_name $TEST_FILES_DIR/test.jpg --yes"
    expect_assets_encrypted "$db_dir"

    # Verify with both CLIs and compare the results.
    local ts_verify_output
    local zig_verify_output
    invoke_command "Verify with TypeScript" "$ts_cli verify --db $db_dir --key $key_name --yes" 0 "ts_verify_output"
    invoke_command "Verify with Zig" "$zig_cli verify --db $db_dir --key $key_name --yes" 0 "zig_verify_output"
    expect_output_string "$zig_verify_output" "Database verification passed - all files are intact" "Zig verify passes on the TypeScript encrypted database"
    expect_same_verify_counts "$ts_verify_output" "$zig_verify_output"

    local zig_full_output
    invoke_command "Full verify with Zig" "$zig_cli verify --db $db_dir --key $key_name --full --yes" 0 "zig_full_output"
    expect_output_string "$zig_full_output" "Database verification passed - all files are intact" "Zig full verify passes on the TypeScript encrypted database"

    test_passed
}

test_zig_verify_ts_encrypted_db "${1:-05}"
