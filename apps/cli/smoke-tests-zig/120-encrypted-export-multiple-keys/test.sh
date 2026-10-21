#!/bin/bash
DESCRIPTION="Export with both keys; verify exports match originals"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_export_with_multiple_keys() {
    local test_number="$1"
    local name="export-with-multiple-keys"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key1_name="multi-exp-key1"
    local key2_name="multi-exp-key2"

    mkdir -p "$test_dir"
    mkdir -p "$export_dir"

    # Create encrypted database with key1 (official key).
    invoke_command "Init encrypted database with key1" "$cli init --db \"$db_dir\" --key \"$key1_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key1_name"

    # Ensure key2 exists (generate via throwaway database).
    invoke_command "Generate key2" "$cli init --db \"$test_dir/tmp-key2-db\" --key \"$key2_name\" --generate-key --yes"

    ts_verify "$test_dir/tmp-key2-db" --key "$key2_name"

    # Add first file with key1 (encrypted with key1).
    invoke_command "Add first PNG with key1" "$cli add --db \"$db_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$db_dir" --key "$key1_name"

    # Add second file with key2,key1 so key2 is write key (encrypted with key2).
    invoke_command "Add second JPG with key2" "$cli add --db \"$db_dir\" --key \"$key2_name,$key1_name\" \"$TEST_FILES_DIR/test.jpg\" --yes"

    ts_verify "$db_dir" --key "$key2_name,$key1_name"

    # Look up asset IDs via list.
    local asset_id1
    local multi_keys="$key1_name,$key2_name"
    asset_id1=$(get_asset_id_for_filename "$db_dir" "$multi_keys" "test.png") || test_failed "$name"

    local asset_id2
    asset_id2=$(get_asset_id_for_filename "$db_dir" "$multi_keys" "test.jpg") || test_failed "$name"

    local export1="$export_dir/export1.png"
    local export2="$export_dir/export2.jpg"

    invoke_command "Export first asset with both keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id1\" \"$export1\" --yes"

    invoke_command "Export second asset with both keys" "$cli export --db \"$db_dir\" --key \"$multi_keys\" \"$asset_id2\" \"$export2\" --yes"

    if [ ! -f "$export1" ] || [ ! -f "$export2" ]; then
        log_error "Expected exported files not found in $export_dir"
        test_failed "$name"
    fi

    if ! cmp -s "$TEST_FILES_DIR/test.png" "$export1"; then
        log_error "Exported PNG does not match original"
        test_failed "$name"
    fi

    if ! cmp -s "$TEST_FILES_DIR/test.jpg" "$export2"; then
        log_error "Exported JPG does not match original"
        test_failed "$name"
    fi

    test_passed
}

test_export_with_multiple_keys "${1:-120}"
