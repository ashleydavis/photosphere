#!/bin/bash
DESCRIPTION="psi remove-orphans deletes the files the merkle tree does not know about, and nothing else"

# find-orphans is run by the S3 tests; this test runs its sibling, which deletes what find-orphans
# reports, on a local database the Zig CLI built. Each command's whole output is checked against the
# text expected of it, and the cleaned database is expected to be the database as it was before the
# orphans were put into it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs a command with the Zig CLI on a database and expects it to print the expected text once the
# database's path is replaced by <db>. The output goes into the named variable.
#
expect_orphans_output() {
    local description="$1"
    local command_name="$2"
    local db_dir="$3"
    local expected_output="$4"
    local output_var_name="$5"

    local orphans_output
    invoke_command "$description" "$(get_zig_cli_command) -q $command_name --db \"$db_dir\" --yes" 0 "orphans_output"

    expect_value "${orphans_output//"$db_dir"/<db>}" "$expected_output" "$description: the output is the expected text"

    eval "$output_var_name=\"\$orphans_output\""
}

test_remove_orphans() {
    local test_number="$1"
    print_test_header "$test_number" "REMOVE ORPHANS"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/orphans-db"
    local clean_db_dir="$test_dir/orphans-db-clean"

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    verify_database "$db_dir"
    invoke_command "Add a PNG file" "$(get_zig_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes"
    verify_database "$db_dir"
    local asset_id
    asset_id="$(ls "$db_dir/asset")"

    local root_hash_before
    invoke_command "Get the root hash" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "root_hash_before"

    # --- 1. Nothing to remove in a database the CLI wrote. ---

    local clean_output
    invoke_command "Remove orphans from a database that has none" "$(get_zig_cli_command) -q remove-orphans --db \"$db_dir\" --yes" 0 "clean_output"
    verify_database "$db_dir"
    expect_output_string "$clean_output" "No orphaned files found" "A database the CLI wrote has no orphans"

    # --- 2. Files nothing in the database refers to. ---

    cp -Rp "$db_dir" "$clean_db_dir"
    cp "$TEST_FILES_DIR/test.jpg" "$db_dir/asset/orphan-asset"
    cp "$TEST_FILES_DIR/test.jpg" "$db_dir/display/orphan-display"
    cp "$TEST_FILES_DIR/test.webp" "$db_dir/thumb/orphan-thumb"

    local find_output
    expect_orphans_output "Find the orphans" "find-orphans" "$db_dir" "
Finding orphaned files in database:
  Database: <db>


📋 Orphaned Files

  ✗ asset/orphan-asset
  ✗ display/orphan-display
  ✗ thumb/orphan-thumb

⚠️  Found 3 orphaned file(s) that exist in storage but are not tracked in the merkle tree.
     Use 'psi remove-orphans' to remove them." "find_output"
    expect_output_string "$find_output" "Found 3 orphaned file(s)" "The three untracked files are orphans"

    local remove_output
    expect_orphans_output "Remove the orphans" "remove-orphans" "$db_dir" "
Finding orphaned files in database:
  Database: <db>


🗑️  Remove Orphaned Files

  ✗ asset/orphan-asset
  ✗ display/orphan-display
  ✗ thumb/orphan-thumb


✓ Successfully deleted 3 orphaned file(s)" "remove_output"
    verify_database "$db_dir"
    local orphan_path
    for orphan_path in asset/orphan-asset display/orphan-display thumb/orphan-thumb; do
        expect_output_string "$remove_output" "✗ $orphan_path$" "$orphan_path is listed for removal"
        if [ -e "$db_dir/$orphan_path" ]; then
            log_error "$orphan_path is still in the database after remove-orphans"
            exit 1
        fi
        log_success "$orphan_path is gone"
    done
    expect_output_string "$remove_output" "Successfully deleted 3 orphaned file(s)" "The three orphans are deleted"

    # --- 3. What the database refers to is untouched. ---

    check_exists "$db_dir/asset/$asset_id" "The asset file"
    check_exists "$db_dir/display/$asset_id" "The display file"
    check_exists "$db_dir/thumb/$asset_id" "The thumbnail file"

    local root_hash_after
    invoke_command "Get the root hash after the removal" "$(get_zig_cli_command) -q root-hash --db \"$db_dir\" --yes" 0 "root_hash_after"
    expect_value "$root_hash_after" "$root_hash_before" "Removing the orphans left the database's contents as they were"

    if ! diff -r "$db_dir" "$clean_db_dir"; then
        log_error "remove-orphans left the database different from the copy taken before the orphans were put in"
        exit 1
    fi
    log_success "remove-orphans left the database as it was before the orphans were put in"

    local again_output
    expect_orphans_output "Remove orphans again" "remove-orphans" "$db_dir" "
Finding orphaned files in database:
  Database: <db>


🗑️  Remove Orphaned Files

✓ No orphaned files found" "again_output"
    expect_output_string "$again_output" "No orphaned files found" "Nothing is left to remove"

    invoke_command "Verify the database" "$(get_zig_cli_command) verify --db \"$db_dir\" --yes"

    test_passed
}

test_remove_orphans "${1:-99}"
