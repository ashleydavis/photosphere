#!/bin/bash
DESCRIPTION="Two assets with different keys; list shows encryption; export both; verify match originals"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_multi_key_encrypt() {
    local test_number="$1"
    local name="multi-key-encrypt"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db1_dir="$test_dir/encrypted-db1"
    local db2_dir="$test_dir/encrypted-db2"
    local export_dir="$test_dir/export"
    local key1_name="multi-enc-key1"
    local key2_name="multi-enc-key2"

    mkdir -p "$test_dir"
    mkdir -p "$export_dir"

    # Create two encrypted DBs with different keys, add two assets to each.
    invoke_command "Init encrypted database 1 with key1" "$cli init --db \"$db1_dir\" --key \"$key1_name\" --generate-key --yes"

    ts_verify "$db1_dir" --key "$key1_name"

    invoke_command "Init encrypted database 2 with key2" "$cli init --db \"$db2_dir\" --key \"$key2_name\" --generate-key --yes"

    ts_verify "$db2_dir" --key "$key2_name"

    invoke_command "Add PNG and JPG to DB1 (key1)" "$cli add --db \"$db1_dir\" --key \"$key1_name\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" --yes"

    ts_verify "$db1_dir" --key "$key1_name"

    invoke_command "Add PNG and JPG to DB2 (key2)" "$cli add --db \"$db2_dir\" --key \"$key2_name\" \"$TEST_FILES_DIR/test.png\" \"$TEST_FILES_DIR/test.jpg\" --yes"

    ts_verify "$db2_dir" --key "$key2_name"

    # Simulate failed re-encrypt: take one asset from DB2 (key2) and overwrite same slot in DB1. Now DB1 has one asset with key1, one with key2.
    local asset_id_jpg_db1 asset_id_jpg_db2
    asset_id_jpg_db1=$(get_asset_id_for_filename "$db1_dir" "$key1_name" "test.jpg") || test_failed "$name"
    asset_id_jpg_db2=$(get_asset_id_for_filename "$db2_dir" "$key2_name" "test.jpg") || test_failed "$name"

    log_info "Overwriting DB1 asset $asset_id_jpg_db1 with DB2 file (key2) to simulate partial re-encrypt"
    if ! cp "$db2_dir/asset/$asset_id_jpg_db2" "$db1_dir/asset/$asset_id_jpg_db1"; then
        log_error "Failed to copy asset from DB2 to DB1"
        test_failed "$name"
    fi

    # Export from DB1 with both keys; PNG is key1, JPG is key2.
    local asset_id_png
    asset_id_png=$(get_asset_id_for_filename "$db1_dir" "$key1_name,$key2_name" "test.png") || test_failed "$name"
    asset_id_jpg_db1=$(get_asset_id_for_filename "$db1_dir" "$key1_name,$key2_name" "test.jpg") || test_failed "$name"

    local multi_keys="$key1_name,$key2_name"
    local export1="$export_dir/out1.png"
    local export2="$export_dir/out2.jpg"
    invoke_command "Export PNG (key1)" "$cli export --db \"$db1_dir\" --key \"$multi_keys\" \"$asset_id_png\" \"$export1\" --yes"
    invoke_command "Export JPG (key2)" "$cli export --db \"$db1_dir\" --key \"$multi_keys\" \"$asset_id_jpg_db1\" \"$export2\" --yes"

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

test_multi_key_encrypt "${1:-121}"
