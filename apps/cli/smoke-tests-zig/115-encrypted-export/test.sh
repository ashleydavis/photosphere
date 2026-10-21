#!/bin/bash
DESCRIPTION="Export asset from encrypted DB (decrypted output)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_export_encrypted_file() {
    local test_number="$1"
    local name="export-encrypted-file"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key_name="export-enc-key"

    mkdir -p "$test_dir"
    mkdir -p "$export_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Add PNG file to encrypted database" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    local asset_id
    asset_id=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || test_failed "$name"

    local export_path="$export_dir/exported.png"
    invoke_command "Export encrypted asset" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id\" \"$export_path\" --yes"

    if [ ! -f "$export_path" ]; then
        log_error "Expected exported file not found: $export_path"
        test_failed "$name"
    fi

    # Exported file should be plain (no PSEN header).
    local tag
    tag=$(read_magic_tag "$export_path")
    if [ "$tag" = "PSEN" ]; then
        log_error "Exported file appears to be encrypted (has PSEN header): $export_path"
        test_failed "$name"
    fi

    test_passed
}

test_export_encrypted_file "${1:-115}"
