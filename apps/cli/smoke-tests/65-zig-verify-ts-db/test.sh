#!/bin/bash
DESCRIPTION="Zig CLI verifies a database created by the TypeScript CLI"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/functions.sh"
trap cleanup_and_show_summary EXIT

test_zig_verify_ts_db() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG VERIFY OF A TYPESCRIPT DATABASE"

    local test_dir=$(get_test_dir "$test_number")
    local db_dir="$test_dir/ts-db"
    local ts_cli="$(get_ts_cli_command)"
    local zig_cli="$(get_zig_cli_command)"

    check_exists "$zig_cli" "Zig CLI binary"

    # Create and populate the database with the TypeScript CLI.
    invoke_command "Initialize database with TypeScript" "$ts_cli init --db $db_dir --yes"
    invoke_command "Add PNG file with TypeScript" "$ts_cli add --db $db_dir $TEST_FILES_DIR/test.png --yes"
    invoke_command "Add JPG file with TypeScript" "$ts_cli add --db $db_dir $TEST_FILES_DIR/test.jpg --yes"
    invoke_command "Add MP4 file with TypeScript" "$ts_cli add --db $db_dir $TEST_FILES_DIR/multiple-files/test.mp4 --yes"
    invoke_command "Add multiple images with TypeScript" "$ts_cli add --db $db_dir $MULTIPLE_IMAGES_DIR/ --yes"

    # Verify with both CLIs and compare the results.
    local ts_verify_output
    local zig_verify_output
    invoke_command "Verify with TypeScript" "$ts_cli verify --db $db_dir --yes" 0 "ts_verify_output"
    invoke_command "Verify with Zig" "$zig_cli verify --db $db_dir --yes" 0 "zig_verify_output"
    expect_output_string "$zig_verify_output" "Database verification passed - all files are intact" "Zig verify passes on the TypeScript database"
    expect_same_verify_counts "$ts_verify_output" "$zig_verify_output"

    # Full verify with both CLIs.
    local ts_full_output
    local zig_full_output
    invoke_command "Full verify with TypeScript" "$ts_cli verify --db $db_dir --full --yes" 0 "ts_full_output"
    invoke_command "Full verify with Zig" "$zig_cli verify --db $db_dir --full --yes" 0 "zig_full_output"
    expect_output_string "$zig_full_output" "Database verification passed - all files are intact" "Zig full verify passes on the TypeScript database"
    expect_same_verify_counts "$ts_full_output" "$zig_full_output"

    # Damage a file and check both CLIs detect it the same way.
    local asset_file=$(find "$db_dir/asset" -type f | sort | head -1)
    echo "damaged" >> "$asset_file"
    local ts_damaged_output
    local zig_damaged_output
    invoke_command "Verify damaged database with TypeScript" "$ts_cli verify --db $db_dir --yes" 0 "ts_damaged_output"
    invoke_command "Verify damaged database with Zig" "$zig_cli verify --db $db_dir --yes" 0 "zig_damaged_output"
    expect_output_value "$zig_damaged_output" "Modified:" "1" "Zig verify detects the modified file"
    expect_same_verify_counts "$ts_damaged_output" "$zig_damaged_output"

    test_passed
}

test_zig_verify_ts_db "${1:-65}"
