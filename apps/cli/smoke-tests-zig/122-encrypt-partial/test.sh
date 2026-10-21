#!/bin/bash
DESCRIPTION="One encrypted, one plain asset; list shows both; export with key; verify match originals"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_partial_encrypt() {
    local test_number="$1"
    local name="partial-encrypt"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/encrypted-db"
    local export_dir="$test_dir/export"
    local key_name="partial-enc-key"

    mkdir -p "$test_dir"
    mkdir -p "$export_dir"

    # Create encrypted DB and add two assets (both encrypted).
    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Add PNG (encrypted)" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    invoke_command "Add JPG (encrypted)" "$cli add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.jpg\" --yes"

    ts_verify "$db_dir" --key "$key_name"

    # Simulate failed encrypt: replace second asset file with plain content (one encrypted, one plain).
    local asset_id2
    asset_id2=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.jpg") || test_failed "$name"
    if [ ! -d "$db_dir/asset" ]; then
        log_error "Expected asset directory $db_dir/asset"
        test_failed "$name"
    fi
    log_info "Overwriting asset $asset_id2 with plain file (simulate partial encrypt failure)"
    if ! cp "$TEST_FILES_DIR/test.jpg" "$db_dir/asset/$asset_id2"; then
        log_error "Failed to overwrite asset with plain file"
        test_failed "$name"
    fi

    local asset_id1
    asset_id1=$(get_asset_id_for_filename "$db_dir" "$key_name" "test.png") || test_failed "$name"

    local export1="$export_dir/out.png"
    local export2="$export_dir/out.jpg"
    invoke_command "Export PNG (encrypted)" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id1\" \"$export1\" --yes"
    invoke_command "Export JPG (plain)" "$cli export --db \"$db_dir\" --key \"$key_name\" \"$asset_id2\" \"$export2\" --yes"

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

test_partial_encrypt "${1:-122}"
