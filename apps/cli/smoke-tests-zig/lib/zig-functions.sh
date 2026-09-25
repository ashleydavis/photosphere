#!/bin/bash

# Zig versions of the smoke-test functions in smoke-tests/lib/functions.sh that run `psi verify` or
# `psi replicate`. Sources the original functions.sh (left unchanged) and then redefines only those
# functions, each a verbatim copy of the original with the verify and replicate commands run through
# the Zig CLI ($(get_zig_cli_command)) instead of $(get_cli_command). Every other command still runs
# in the TypeScript CLI.
# Sourced by the Zig smoke tests after smoke-tests/lib/common.sh and lib/interop.sh.

# The original test functions, the ones not redefined below are used as they are.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../smoke-tests/lib/functions.sh"

# Zig version of test_database_verify from smoke-tests/lib/functions.sh.
test_database_verify() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE VERIFICATION"

    log_info "Database path: $TEST_DB_DIR"

    # Show database structure with tree command
    log_info "Showing database structure..."
    show_tree "$TEST_DB_DIR"

    # Run verify command and capture output for checking
    local verify_output
    invoke_command "Verify database integrity" "$(get_zig_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"

    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Verify output contains total size"

    # Check that the database is in a good state (no new, modified, or removed files)
    expect_output_value "$verify_output" "Files imported:" "7" "File imported"
    expect_output_value "$verify_output" "Unmodified:" "20" "Unmodified files in verification"
    expect_output_value "$verify_output" "New:" "0" "New files in verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in verification"
    test_passed
}

# Zig version of test_database_verify_full from smoke-tests/lib/functions.sh.
test_database_verify_full() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE VERIFICATION (FULL MODE)"

    log_info "Database path: $TEST_DB_DIR"

    # Run full verify command and capture output for checking
    local verify_output
    invoke_command "Verify database (full mode)" "$(get_zig_cli_command) verify --db $TEST_DB_DIR --full --yes" 0 "verify_output"

    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Full verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Full verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Full verify output contains total size"

    # Check that the database is in a good state even with full verification
    expect_output_value "$verify_output" "Unmodified:" "20" "Unmodified files in full verification"
    expect_output_value "$verify_output" "New:" "0" "New files in full verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in full verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in full verification"
    test_passed
}

# Zig version of test_detect_deleted_file from smoke-tests/lib/functions.sh.
test_detect_deleted_file() {
    local test_number="$1"
    print_test_header "$test_number" "DETECT DELETED FILE WITH VERIFY"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local test_copy_dir="$test_dir/test-db-deleted-file-test"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Test copy database path: $test_copy_dir"

    # Ensure source database exists before copying
    if [ ! -d "$TEST_DB_DIR" ]; then
        log_error "Source database not found at $TEST_DB_DIR. Run previous tests first."
        exit 1
    fi

    if [ ! -d "$TEST_DB_DIR/.db" ]; then
        log_error "Source database .db subdirectory not found at $TEST_DB_DIR/.db"
        exit 1
    fi

    # Create fresh copy of database for testing
    log_info "Creating fresh copy of database for deleted file test"

    # Ensure destination doesn't exist to avoid copying into subdirectory
    rm -rf "$test_copy_dir"

    log_info "Copying database: cp -r \"$TEST_DB_DIR\" \"$test_copy_dir\""
    cp -r "$TEST_DB_DIR" "$test_copy_dir"

    # Verify the copy includes the .db subdirectory
    if [ ! -d "$test_copy_dir/.db" ]; then
        log_error "Failed to copy .db subdirectory to $test_copy_dir"
        exit 1
    fi

    # Find and delete the first file from the asset directory
    local file_to_delete=$(find "$test_copy_dir/asset" -type f | sort | head -1)
    if [ -n "$file_to_delete" ]; then
        local relative_path="${file_to_delete#$test_copy_dir/}"
        rm "$file_to_delete"
        log_info "Deleted file: $relative_path"
    else
        log_error "No file found in asset directory to delete"
        exit 1
    fi

    # Run verify and capture output - should detect the missing file
    #
    # Exit 1, because the database is broken and verify says so. It used to exit 0 whatever it found,
    # so the result lived only in the words on the screen and anything reading the exit code was told
    # a broken database was fine.
    local verify_output
    invoke_command "Verify database with deleted file" "$(get_zig_cli_command) verify --db $test_copy_dir --yes" 1 "verify_output"

    # Check that verify detected the removed file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "19" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files"
    expect_output_value "$verify_output" "Removed:" "1" "Deleted file detected by verify"

    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

# Zig version of test_detect_modified_file from smoke-tests/lib/functions.sh.
test_detect_modified_file() {
    local test_number="$1"
    print_test_header "$test_number" "DETECT MODIFIED FILE WITH VERIFY"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local test_copy_dir="$test_dir/test-db-modified-file-test"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Test copy database path: $test_copy_dir"

    # Ensure source database exists before copying
    if [ ! -d "$TEST_DB_DIR" ]; then
        log_error "Source database not found at $TEST_DB_DIR. Run previous tests first."
        exit 1
    fi

    if [ ! -d "$TEST_DB_DIR/.db" ]; then
        log_error "Source database .db subdirectory not found at $TEST_DB_DIR/.db"
        exit 1
    fi

    # Create fresh copy of database for testing
    log_info "Creating fresh copy of database for modified file test"

    # Ensure destination doesn't exist to avoid copying into subdirectory
    rm -rf "$test_copy_dir"

    log_info "Copying database: cp -r \"$TEST_DB_DIR\" \"$test_copy_dir\""
    cp -r "$TEST_DB_DIR" "$test_copy_dir"

    # Verify the copy includes the .db subdirectory
    if [ ! -d "$test_copy_dir/.db" ]; then
        log_error "Failed to copy .db subdirectory to $test_copy_dir"
        exit 1
    fi

    # Find and modify the first file from the asset directory
    local file_to_modify=$(find "$test_copy_dir/asset" -type f | sort | head -1)
    if [ -n "$file_to_modify" ]; then
        local relative_path="${file_to_modify#$test_copy_dir/}"
        # Append some data to modify the file
        echo "Modified content" >> "$file_to_modify"
        log_info "Modified file: $relative_path"
    else
        log_error "No file found in asset directory to modify"
        exit 1
    fi

    # Run verify and capture output - should detect the modified file
    local verify_output
    # Exit 1: the file's bytes no longer match its hash, which is what verify is for.
    invoke_command "Verify database with modified file" "$(get_zig_cli_command) verify --db $test_copy_dir --yes" 1 "verify_output"

    # Check that verify detected the modified file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "19" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "1" "Modified file detected by verify"
    expect_output_value "$verify_output" "Removed:" "0" "No removed files"

    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

# Zig version of test_database_replicate from smoke-tests/lib/functions.sh.
test_database_replicate() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE REPLICATION"

    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"

    # Clean up any existing replica
    if [ -d "$replica_dir" ]; then
        log_info "Cleaning up existing replica directory"
        rm -rf "$replica_dir"
    fi

    # Run replicate command and capture output
    local replicate_output
    invoke_command "Replicate database" "$(get_zig_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "replicate_output"

    # Check if replication was successful
    expect_output_string "$replicate_output" "Replication completed successfully" "Database replication completed successfully"

    # Check expected values from replication output
    expect_output_value "$replicate_output" "Total files imported:" "7" "Total files imported"
    expect_output_value "$replicate_output" "Total files copied:" "19" "Files copied"

    # Check that replica was created
    check_exists "$replica_dir" "Replica database directory"
    check_exists "$replica_dir/.db" "Replica metadata directory"
    check_exists "$replica_dir/.db/files.dat" "Replica tree file"

    # Verify original and replica have the same aggregate root hash
    verify_root_hashes_match "$TEST_DB_DIR" "$replica_dir" "original and replica"

    # Verify original and replica have the same database ID
    log_info "Verifying database IDs match for original and replica"
    local source_id_output
    local replica_id_output
    invoke_command "Get source database ID" "$(get_cli_command) database-id --db $TEST_DB_DIR --yes" 0 "source_id_output"
    invoke_command "Get replica database ID" "$(get_cli_command) database-id --db $replica_dir --yes" 0 "replica_id_output"

    local source_id=$(echo "$source_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local replica_id=$(echo "$replica_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

    if [ "$source_id" = "$replica_id" ]; then
        log_success "Database IDs match: $source_id"
    else
        log_error "Database IDs do not match"
        log_error "Source ID: $source_id"
        log_error "Replica ID: $replica_id"
        exit 1
    fi

    # Get source and replica summaries to compare files imported count
    local source_summary
    invoke_command "Get source database summary" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "source_summary"

    local replica_summary
    invoke_command "Get replica database summary" "$(get_cli_command) summary --db $replica_dir --yes" 0 "replica_summary"

    # Extract and compare files imported count
    local source_files_imported=$(parse_numeric "$source_summary" "Files imported:")
    local replica_files_imported=$(parse_numeric "$replica_summary" "Files imported:")
    expect_value "$replica_files_imported" "$source_files_imported" "Replica files imported count matches source"

    # Check merkle tree order for both original and replica
    check_merkle_tree_order "$replica_dir/.db/files.dat" "replica database"

    # Verify the replica's origin points back to the source
    local origin_output
    invoke_command "Get replica origin" "$(get_cli_command) origin --db $replica_dir --yes" 0 "origin_output"
    local origin_value=$(echo "$origin_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    expect_value "$origin_value" "$TEST_DB_DIR" "Replica origin matches source path"

    test_passed
}

# Zig version of test_verify_replica from smoke-tests/lib/functions.sh.
test_verify_replica() {
    local test_number="$1"
    print_test_header "$test_number" "VERIFY REPLICA"

    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"

    # Check that replica exists from previous test
    check_exists "$replica_dir" "Replica directory from previous test"

    # Verify replica contents match source
    local replica_verify_output
    invoke_command "Verify replica integrity" "$(get_zig_cli_command) verify --db $replica_dir --yes" 0 "replica_verify_output"

    # Get source and replica summaries to compare file counts
    local source_summary
    invoke_command "Get source database summary" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "source_summary"

    local replica_summary
    invoke_command "Get replica database summary" "$(get_cli_command) summary --db $replica_dir --yes" 0 "replica_summary"

    # Extract and compare file counts
    local source_files=$(parse_numeric "$source_summary" "Total files:")
    local replica_files=$(parse_numeric "$replica_summary" "Total files:")
    expect_value "$replica_files" "$source_files" "Replica file count matches source"

    # Extract and compare node counts
    local source_nodes=$(parse_numeric "$source_summary" "Total nodes:")
    local replica_nodes=$(parse_numeric "$replica_summary" "Total nodes:")
    expect_value "$replica_nodes" "$source_nodes" "Replica node count matches source"

    # Verify the replica verify command also shows the expected counts
    expect_output_value "$replica_verify_output" "Total files:" "$source_files" "Replica verify shows correct file count"

    # Verify the replica's origin points back to the source
    local origin_output
    invoke_command "Get replica origin" "$(get_cli_command) origin --db $replica_dir --yes" 0 "origin_output"
    local origin_value=$(echo "$origin_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    expect_value "$origin_value" "$TEST_DB_DIR" "Replica origin matches source path"

    test_passed
}

# Zig version of test_database_replicate_second from smoke-tests/lib/functions.sh.
test_database_replicate_second() {
    local test_number="$1"
    print_test_header "$test_number" "SECOND DATABASE REPLICATION - NO CHANGES"

    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"

    # Check that replica exists from previous test
    check_exists "$replica_dir" "Replica directory from previous test"

    # Run second replicate command and capture output
    local second_replication_output
    invoke_command "Second replication (no changes)" "$(get_zig_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "second_replication_output"

    # Check if replication was successful
    expect_output_string "$second_replication_output" "Replication completed successfully" "Second replication completed successfully"

    # Check expected values from second replication output
    expect_output_value "$second_replication_output" "Total files imported:" "7" "Total files imported"
    expect_output_value "$second_replication_output" "Total files copied:" "0" "Files copied (all up to date)"

    # Verify original and replica still have the same aggregate root hash after second replication
    log_info "Verifying original and replica still have the same root hash after second replication"
    verify_root_hashes_match "$TEST_DB_DIR" "$replica_dir" "original and replica after second replication"

    # Check merkle tree order for replica
    check_merkle_tree_order "$replica_dir/.db/files.dat" "replica database"

    test_passed
}

# Zig version of test_replicate_after_changes from smoke-tests/lib/functions.sh.
test_replicate_after_changes() {
    local test_number="$1"
    print_test_header "$test_number" "REPLICATE AFTER CHANGES"

    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"

    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"

    # Replicate the changes from original to replica
    local replication_output
    invoke_command "Replicate changes to replica" "$(get_zig_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "replication_output"

    # Check that the 8 changed files were replicated
    expect_output_value "$replication_output" "Total files copied:" "3" "Files copied (the changes)"

    # Run compare command to verify databases are now identical again
    local compare_output
    invoke_command "Compare databases after replication" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"

    # Check that comparison shows no differences after replication
    expect_output_string "$compare_output" "No differences detected" "No differences detected after replicating changes"

    # Verify original and replica have the same aggregate root hash after replication
    log_info "Verifying original and replica have the same root hash after replication"
    verify_root_hashes_match "$TEST_DB_DIR" "$replica_dir" "original and replica after replication"

    # Check merkle tree order for replica
    check_merkle_tree_order "$replica_dir/.db/files.dat" "replica database"

    test_passed
}

# Zig version of test_remove_asset from smoke-tests/lib/functions.sh.
test_remove_asset() {
    local test_number="$1"
    print_test_header "$test_number" "REMOVE ASSET BY ID"

    log_info "Database path: $TEST_DB_DIR"

    # Find an asset ID to remove by listing the asset directory
    local assets_dir="$TEST_DB_DIR/asset"
    local test_asset_id=""

    if [ -d "$assets_dir" ]; then
        test_asset_id=$(ls "$assets_dir" | head -1)
        log_info "Found asset files in asset directory"
    fi

    if [ -z "$test_asset_id" ]; then
        # Fallback: try to get a list of assets using the list command
        local list_output
        if invoke_command "List assets to find available asset IDs" "$(get_cli_command) list --db $TEST_DB_DIR --page-size 50 --yes" 0 "list_output"; then
            # Extract the first asset ID from the list output
            test_asset_id=$(echo "$list_output" | grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" | head -1)
        fi
    fi

    if [ -z "$test_asset_id" ]; then
        log_error "Could not find any asset ID to test removal with"
        exit 1
    fi

    log_info "Using asset ID for removal test: $test_asset_id"

    # Get initial database summary before removal
    local before_summary
    invoke_command "Get database summary before removal" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "before_summary"
    local files_before=$(parse_numeric "$before_summary" "Files imported:")

    # Remove the asset
    local remove_output
    invoke_command "Remove asset from database" "$(get_cli_command) remove --db $TEST_DB_DIR $test_asset_id --verbose --yes" 0 "remove_output"

    # Check that removal was successful
    expect_output_string "$remove_output" "Successfully removed asset" "Asset removal success message"

    # Get database summary after removal
    local after_summary
    invoke_command "Get database summary after removal" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "after_summary"
    local files_after=$(parse_numeric "$after_summary" "Files imported:")

    # Verify one less asset in the database
    local expected_files=$((files_before - 1))
    expect_value "$files_after" "$expected_files" "Asset count decreased by 1 after removal"

    # Try to export the removed asset (should fail)
    invoke_command "Try to export removed asset (should fail)" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $TEST_TMP_DIR/should-fail.png --yes" 1

    # Verify the asset files no longer exist in storage
    local original_file="$TEST_DB_DIR/asset/$test_asset_id"
    local display_file="$TEST_DB_DIR/display/$test_asset_id"
    local thumb_file="$TEST_DB_DIR/thumb/$test_asset_id"

    log_info "Checking that all asset files have been deleted from storage..."

    # Check original asset file
    if [ -f "$original_file" ]; then
        log_error "Original asset file still exists after removal: $original_file"
        log_error "File size: $(stat -c%s "$original_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$original_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Original asset file removed from storage: $original_file"
    fi

    # Check display version file
    if [ -f "$display_file" ]; then
        log_error "Display asset file still exists after removal: $display_file"
        log_error "File size: $(stat -c%s "$display_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$display_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Display asset file removed from storage: $display_file"
    fi

    # Check thumbnail file
    if [ -f "$thumb_file" ]; then
        log_error "Thumbnail asset file still exists after removal: $thumb_file"
        log_error "File size: $(stat -c%s "$thumb_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$thumb_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Thumbnail asset file removed from storage: $thumb_file"
    fi

    # Additional comprehensive check: scan all directories for any files containing the asset ID
    log_info "Performing comprehensive scan for any remaining files with asset ID..."
    local remaining_files=""

    # Check asset directory
    if [ -d "$TEST_DB_DIR/asset" ]; then
        remaining_files=$(find "$TEST_DB_DIR/asset" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in asset directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi

    # Check display directory
    if [ -d "$TEST_DB_DIR/display" ]; then
        remaining_files=$(find "$TEST_DB_DIR/display" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in display directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi

    # Check thumb directory
    if [ -d "$TEST_DB_DIR/thumb" ]; then
        remaining_files=$(find "$TEST_DB_DIR/thumb" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in thumb directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi

    # Check metadata directory
    if [ -d "$TEST_DB_DIR/metadata" ]; then
        remaining_files=$(find "$TEST_DB_DIR/metadata" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in metadata directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi

    # Check the entire database directory recursively for any missed files
    local all_remaining_files=$(find "$TEST_DB_DIR" -name "*$test_asset_id*" -not -path "*/.db/*" 2>/dev/null || true)
    if [ -n "$all_remaining_files" ]; then
        log_error "Found remaining files containing asset ID in database directory:"
        echo "$all_remaining_files"
        log_error "These files should have been removed during asset deletion"
        exit 1
    fi

    log_success "Comprehensive file deletion check passed - no remaining files found for asset $test_asset_id"

    # Verify that the asset ID is no longer in the database listing
    log_info "Verifying asset ID is no longer in database listing..."
    local ls_output
    invoke_command "List database contents after removal" "$(get_cli_command) list --db $TEST_DB_DIR --yes" 0 "ls_output"

    # Check that the removed asset ID is not in the output
    if echo "$ls_output" | grep -q "$test_asset_id"; then
        log_error "Asset ID $test_asset_id still appears in database listing after removal"
        log_error "Database listing output:"
        echo "$ls_output"
        exit 1
    else
        log_success "Asset ID $test_asset_id no longer appears in database listing"
    fi

    # Run verify to make sure the database is still in a good state
    local verify_output
    invoke_command "Verify database after asset removal" "$(get_zig_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"

    # The database should still be consistent
    expect_output_value "$verify_output" "New:" "0" "No new files after removal"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files after removal"

    log_success "Asset removal test completed successfully"
    test_passed
}

# Zig version of test_repair_damaged_database from smoke-tests/lib/functions.sh.
test_repair_damaged_database() {
    local test_number="$1"
    print_test_header "$test_number" "REPAIR DAMAGED DATABASE"

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local replica_dir="$TEST_DB_DIR-replica"
    local damaged_dir="$test_dir/test-db-damaged"
    log_info "Damaged database path: $damaged_dir"
    log_info "Source database path (for repair): $replica_dir"

    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"

    # Create a copy of the database to damage
    log_info "Creating copy of database to damage"
    rm -rf "$damaged_dir"
    log_info "Copying database: cp -r \"$TEST_DB_DIR\" \"$damaged_dir\""
    cp -r "$TEST_DB_DIR" "$damaged_dir"

    # Damage the database by:
    # 1. Deleting one file
    local file_to_delete=$(find "$damaged_dir/asset" -type f | head -1)
    if [ -n "$file_to_delete" ]; then
        local relative_path="${file_to_delete#$damaged_dir/}"
        rm "$file_to_delete"
        log_info "Deleted file to simulate damage: $relative_path"
    else
        log_error "No file found in asset directory to delete"
        exit 1
    fi

    # 2. Corrupting another file (if available)
    local file_to_corrupt=$(find "$damaged_dir/asset" -type f | head -1)
    if [ -n "$file_to_corrupt" ]; then
        local relative_path="${file_to_corrupt#$damaged_dir/}"
        echo "CORRUPTED FILE CONTENT - THIS IS NOT THE ORIGINAL DATA" > "$file_to_corrupt"
        log_info "Corrupted file to simulate damage: $relative_path"
    fi

    # Run verify to detect the damage
    log_info "Running verify to detect damage..."
    local verify_output
    # Exit 1: the database has just been damaged on purpose. The verify after the repair below still
    # expects 0, and that pair is what makes the exit code worth anything.
    invoke_command "Verify damaged database" "$(get_zig_cli_command) verify --db $damaged_dir --yes --full" 1 "verify_output"

    # Verify should detect issues (asset and/or database file problems)
    expect_output_string "$verify_output" "verification found issues" "Verify detects damage"

    # Run repair to fix the issues
    log_info "Running repair to fix issues..."
    local repair_output
    invoke_command "Repair damaged database" "$(get_cli_command) repair --db $damaged_dir --source $replica_dir --yes --full" 0 "repair_output"

    # Repair should fix the issues
    expect_output_string "$repair_output" "Database repair completed successfully" "Repair completes successfully"

    # Should have repaired at least one file
    local repaired_count=$(parse_numeric "$repair_output" "Repaired:")
    if [ "$repaired_count" -gt 0 ]; then
        log_success "Repair fixed $repaired_count files"
    else
        log_error "Repair should have fixed at least one file but repaired count is $repaired_count"
        exit 1
    fi

    # Verify the repair was successful
    log_info "Verifying repair was successful..."
    local final_verify_output
    invoke_command "Verify repaired database" "$(get_zig_cli_command) verify --db $damaged_dir --yes" 0 "final_verify_output"

    expect_output_string "$final_verify_output" "Database verification passed - all files are intact" "Repaired database verifies successfully"

    # Check merkle tree order for repaired database
    check_merkle_tree_order "$damaged_dir/.db/files.dat" "repaired database"

    # Clean up damaged database copy
    rm -rf "$damaged_dir"
    log_success "Cleaned up damaged database copy"
    test_passed
}
