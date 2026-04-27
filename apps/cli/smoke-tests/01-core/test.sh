#!/bin/bash

# Tests 1-26: Core database operations (must run in sequence, share TEST_DB_DIR state).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_create_database() {
    local test_number="$1"
    print_test_header "$test_number" "CREATE DATABASE"

    # Ensure shared directory exists and remove any existing test db so init can run
    mkdir -p "$(dirname "$TEST_DB_DIR")"
    if [ -d "$TEST_DB_DIR" ]; then
        rm -rf "$TEST_DB_DIR"
        log_info "Removed existing test database for clean init"
    fi

    log_info "Database path: $TEST_DB_DIR"

    invoke_command "Initialize new database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"

    # Check if required files were created (v6 layout: BSON under .db/bson)
    check_exists "$TEST_DB_DIR" "Database directory"
    check_exists "$TEST_DB_DIR/.db" "Database metadata directory"
    check_exists "$TEST_DB_DIR/.db/files.dat" "Database tree file"
    check_exists "$TEST_DB_DIR/.db/bson" "BSON data directory (v6)"

    # Test initial state - database creation is verified by file existence checks above
    test_passed
}

test_view_media_files() {
    local test_number="$1"
    print_test_header "$test_number" "VIEW LOCAL MEDIA FILES"

    # Capture the output to validate it
    local info_output
    invoke_command "Show info for test files" "$(get_cli_command) info $TEST_FILES_DIR/ --yes" 0 "info_output"

    # Check that info output doesn't contain "Type: undefined" which indicates a bug
    expect_output_string "$info_output" "Type: undefined" "Info output should not contain 'Type: undefined'" "false"

    # Check that each test file has the correct MIME type
    expect_output_string "$info_output" "Type: image/jpeg" "Info output should contain JPEG MIME type for test.jpg"
    expect_output_string "$info_output" "Type: image/png" "Info output should contain PNG MIME type for test.png"
    expect_output_string "$info_output" "Type: video/mp4" "Info output should contain MP4 MIME type for test.mp4"
    expect_output_string "$info_output" "Type: image/webp" "Info output should contain WebP MIME type for test.webp"
    test_passed
}

test_add_file_parameterized() {
    local file_path="$1"
    local file_type="$2"
    local test_description="$3"
    local expected_mime="$4"
    local asset_type="$5"
    
    # Check if file exists
    check_exists "$file_path" "$file_type test file"
    
    # Get initial database state - count files in metadata collection
    # Use the info command output to track actual media files added
    local before_check=$($(get_cli_command) check --db $TEST_DB_DIR $file_path --yes 2>&1)
    local already_in_db=$(parse_numeric "$before_check" "Already added:")
    
    # Add the file and capture output with verbose logging
    local add_output
    invoke_command "$test_description" "$(get_cli_command) add --db $TEST_DB_DIR $file_path --verbose --yes" 0 "add_output"
    
    # Verify exactly one file was added (or was already there)
    if [ "$already_in_db" -eq "1" ]; then
        # File was already in database
        expect_output_value "$add_output" "Already added:" "1" "$file_type file already in database"
        expect_output_value "$add_output" "Files added:" "0" "$file_type file imported (should be 0 since already exists)"
    else
        # File should be newly added
        expect_output_value "$add_output" "Files added:" "1" "$file_type file imported"
        expect_output_value "$add_output" "Files failed:" "0" "$file_type file failed"
    fi
    
    # Check that the specific file is now in the database
    invoke_command "Check $file_type file added" "$(get_cli_command) check --db $TEST_DB_DIR $file_path --yes"
    
    # Validate the assets in the database
    validate_database_assets "$TEST_DB_DIR" "$file_path" "$expected_mime" "$asset_type" "$add_output"
}

test_add_png_file() {
    local test_number="$1"
    print_test_header "$test_number" "ADD PNG FILE"
    
    log_info "Database path: $TEST_DB_DIR"
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.png" "PNG" "Add PNG file" "image/png" "image"
    
    test_passed
}

test_add_jpg_file() {
    local test_number="$1"
    print_test_header "$test_number" "ADD JPG FILE"
    
    log_info "Database path: $TEST_DB_DIR"
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.jpg" "JPG" "Add JPG file" "image/jpeg" "image"
    
    test_passed
}

test_add_mp4_file() {
    local test_number="$1"
    print_test_header "$test_number" "ADD MP4 FILE"
    
    log_info "Database path: $TEST_DB_DIR"
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.mp4" "MP4" "Add MP4 file" "video/mp4" "video"
    
    test_passed
}

test_add_same_file() {
    local test_number="$1"
    print_test_header "$test_number" "ADD SAME FILE (NO DUPLICATION)"
    
    log_info "Database path: $TEST_DB_DIR"
    
    # Try to re-add the PNG file (should not add it again)
    invoke_command "Re-add same file" "$(get_cli_command) add --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    
    invoke_command "Check file still in database" "$(get_cli_command) check --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    test_passed
}

test_add_multiple_files() {
    local test_number="$1"
    print_test_header "$test_number" "ADD MULTIPLE FILES"
    
    log_info "Database path: $TEST_DB_DIR"
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        local add_output
        invoke_command "Add multiple files" "$(get_cli_command) add --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes" 0 "add_output"
        
        # Check that 2 files were imported
        expect_output_value "$add_output" "Files added:" "2" "Two files imported from multiple images directory"
        
        invoke_command "Check multiple files added" "$(get_cli_command) check --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
    test_passed
}

test_add_same_multiple_files() {
    local test_number="$1"
    print_test_header "$test_number" "ADD SAME MULTIPLE FILES (NO DUPLICATION)"
    
    log_info "Database path: $TEST_DB_DIR"
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        invoke_command "Re-add multiple files" "$(get_cli_command) add --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
        
        invoke_command "Check multiple files still in database" "$(get_cli_command) check --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
    test_passed
}

test_add_duplicate_images() {
    local test_number="$1"
    print_test_header "$test_number" "ADD DUPLICATE IMAGES (DEDUPE TO 1 ASSET)"

    if [ ! -d "$DUPLICATE_IMAGES_DIR" ]; then
        log_warning "Duplicate images directory not found: $DUPLICATE_IMAGES_DIR"
        log_warning "Skipping duplicate images test"
        test_passed
        return 0
    fi

    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local db_dir="$test_dir/duplicate-test-db"
    rm -rf "$db_dir"

    log_info "Creating new database at: $db_dir"
    invoke_command "Initialize new database" "$(get_cli_command) init --db $db_dir --yes"

    local add_output
    invoke_command "Add duplicate images directory" "$(get_cli_command) add --db $db_dir $DUPLICATE_IMAGES_DIR/ --yes" 0 "add_output"

    local summary_output
    invoke_command "Get database summary" "$(get_cli_command) summary --db $db_dir --yes" 0 "summary_output"

    local files_imported=$(parse_numeric "$summary_output" "Files imported:" "0")
    expect_value "$files_imported" "1" "Database should have exactly 1 asset after importing two identical files"

    rm -rf "$db_dir"
    test_passed
}

test_database_summary() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE SUMMARY"
    
    log_info "Database path: $TEST_DB_DIR"
    
    # Run summary command and capture output for verification
    local summary_output
    invoke_command "Display database summary" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "summary_output"
    
    # Check that summary contains expected fields
    expect_output_string "$summary_output" "Files imported:" "Summary contains files imported count"
    expect_output_string "$summary_output" "Total files:" "Summary contains total files count"
    expect_output_string "$summary_output" "Total size:" "Summary contains total size"
    expect_output_string "$summary_output" "Full root hash:" "Summary contains full root hash"
    test_passed
}

test_database_list() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE LIST"
    
    log_info "Database path: $TEST_DB_DIR"
    
    # Run list command and capture output for verification
    local list_output
    invoke_command "List database files" "$(get_cli_command) list --db $TEST_DB_DIR --page-size 10 --yes" 0 "list_output"
    
    # Check that list contains expected fields and patterns
    expect_output_string "$list_output" "Database Files" "List output contains header"
    expect_output_string "$list_output" "sorted by date" "List output contains sorting information"
    expect_output_string "$list_output" "Page 1" "List output contains page header"
    expect_output_string "$list_output" "Date:" "List output contains date information"
    expect_output_string "$list_output" "Size:" "List output contains size information"
    expect_output_string "$list_output" "Type:" "List output contains type information"
    expect_output_string "$list_output" "Encryption:" "List output contains encryption information"
    expect_output_string "$list_output" "unencrypted" "List output shows unencrypted status for plain database"

    # Check that it shows the expected number of files
    expect_output_string "$list_output" "End of results" "List shows end of results message"
    expect_output_string "$list_output" "Displayed 5 files total" "List shows correct total file count"
    test_passed
}

test_export_assets() {
    local test_number="$1"
    print_test_header "$test_number" "EXPORT ASSETS"
    
    log_info "Database path: $TEST_DB_DIR"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    # Create export test directory
    local export_dir="$test_dir/exports"
    mkdir -p "$export_dir"
    
    # Try to find assets in the database directory directly first
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
            # The list output should contain lines with asset IDs
            test_asset_id=$(echo "$list_output" | grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" | head -1)
        fi
    fi
    
    if [ -z "$test_asset_id" ]; then
        log_error "Could not find any asset ID to test export with"
        log_info "List output:"
        echo "$list_output"
        log_info "Assets directory contents:"
        ls -la "$TEST_DB_DIR/asset" || echo "Assets directory not found"
        exit 1
    fi
    
    log_info "Using asset ID for export tests: $test_asset_id"
    
    # Test 1: Export original asset to specific file
    local export_output
    invoke_command "Export original asset to specific file" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/exported-original.png --verbose --yes" 0 "export_output"
    
    # Verify the exported file exists
    check_exists "$export_dir/exported-original.png" "Exported original file"
    
    # Check export output for success message
    expect_output_string "$export_output" "Successfully exported" "Export success message"
    
    # Test 2: Export display version to directory (if it exists)
    local display_file="$TEST_DB_DIR/display/$test_asset_id"
    if [ -f "$display_file" ]; then
        invoke_command "Export display version to directory" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/ --type display --verbose --yes"
        
        # Check if the display file was exported (name will depend on original filename)
        local exported_display_count=$(find "$export_dir" -name "*_display.*" | wc -l)
        if [ "$exported_display_count" -eq 0 ]; then
            log_warning "Display version export didn't create expected _display file"
        else
            log_success "Display version exported successfully"
        fi
    else
        log_info "Display version not available for asset $test_asset_id, skipping display export test"
    fi
    
    # Test 3: Export thumbnail version (if it exists)
    local thumb_file="$TEST_DB_DIR/thumb/$test_asset_id"
    if [ -f "$thumb_file" ]; then
        invoke_command "Export thumbnail version" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/thumb.jpg --type thumb --verbose --yes"
        
        check_exists "$export_dir/thumb.jpg" "Exported thumbnail file"
    else
        log_info "Thumbnail version not available for asset $test_asset_id, skipping thumbnail export test"
    fi
    
    # Test 4: Try to export non-existent asset (should fail)
    local invalid_asset_id="00000000-0000-0000-0000-000000000000"
    invoke_command "Export non-existent asset (should fail)" "$(get_cli_command) export --db $TEST_DB_DIR $invalid_asset_id $export_dir/should-not-exist.png --yes" 1
    
    # Test 5: Export the same asset explicitly as original type
    invoke_command "Export asset as original explicitly" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/explicit-original.png --type original --verbose --yes"
    
    check_exists "$export_dir/explicit-original.png" "Explicitly exported original file"
    
    log_success "All export tests completed successfully"
    test_passed
}

test_database_verify() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE VERIFICATION"
    
    log_info "Database path: $TEST_DB_DIR"
    
    # Show database structure with tree command
    log_info "Showing database structure..."
    show_tree "$TEST_DB_DIR"
    
    # Run verify command and capture output for checking
    local verify_output
    invoke_command "Verify database integrity" "$(get_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"
    
    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Verify output contains total size"
    
    # Check that the database is in a good state (no new, modified, or removed files)
    expect_output_value "$verify_output" "Files imported:" "5" "File imported"
    expect_output_value "$verify_output" "Unmodified:" "15" "Unmodified files in verification"
    expect_output_value "$verify_output" "New:" "0" "New files in verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in verification"
    test_passed
}

test_database_verify_full() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE VERIFICATION (FULL MODE)"
    
    log_info "Database path: $TEST_DB_DIR"
    
    # Run full verify command and capture output for checking
    local verify_output
    invoke_command "Verify database (full mode)" "$(get_cli_command) verify --db $TEST_DB_DIR --full --yes" 0 "verify_output"
    
    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Full verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Full verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Full verify output contains total size"
    
    # Check that the database is in a good state even with full verification
    expect_output_value "$verify_output" "Unmodified:" "15" "Unmodified files in full verification"
    expect_output_value "$verify_output" "New:" "0" "New files in full verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in full verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in full verification"
    test_passed
}

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
    local verify_output
    invoke_command "Verify database with deleted file" "$(get_cli_command) verify --db $test_copy_dir --yes" 0 "verify_output"
    
    # Check that verify detected the removed file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "14" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files"
    expect_output_value "$verify_output" "Removed:" "1" "Deleted file detected by verify"
    
    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

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
    invoke_command "Verify database with modified file" "$(get_cli_command) verify --db $test_copy_dir --yes" 0 "verify_output"
    
    # Check that verify detected the modified file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "14" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "1" "Modified file detected by verify"
    expect_output_value "$verify_output" "Removed:" "0" "No removed files"
    
    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

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
    invoke_command "Replicate database" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "replicate_output"
    
    # Check if replication was successful
    expect_output_string "$replicate_output" "Replication completed successfully" "Database replication completed successfully"
    
    # Check expected values from replication output
    expect_output_value "$replicate_output" "Total files imported:" "5" "Total files imported"
    expect_output_value "$replicate_output" "Total files copied:" "14" "Files copied"
    
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
    
    test_passed
}

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
    invoke_command "Verify replica integrity" "$(get_cli_command) verify --db $replica_dir --yes" 0 "replica_verify_output"
    
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
    test_passed
}

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
    invoke_command "Second replication (no changes)" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "second_replication_output"
    
    # Check if replication was successful
    expect_output_string "$second_replication_output" "Replication completed successfully" "Second replication completed successfully"
    
    # Check expected values from second replication output
    expect_output_value "$second_replication_output" "Total files imported:" "5" "Total files imported"
    expect_output_value "$second_replication_output" "Total files copied:" "0" "Files copied (all up to date)"
    
    # Verify original and replica still have the same aggregate root hash after second replication
    log_info "Verifying original and replica still have the same root hash after second replication"
    verify_root_hashes_match "$TEST_DB_DIR" "$replica_dir" "original and replica after second replication"
    
    # Check merkle tree order for replica
    check_merkle_tree_order "$replica_dir/.db/files.dat" "replica database"
    
    test_passed
}

test_database_compare() {
    local test_number="$1"
    print_test_header "$test_number" "DATABASE COMPARISON"
    
    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Test comparison between original and replica (should show no differences)
    local compare_output
    invoke_command "Compare original database with replica" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison shows no differences for identical databases
    expect_output_string "$compare_output" "No differences detected" "No differences detected between databases"
    
    # Test comparison with self (database vs itself)
    invoke_command "Compare database with itself" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $TEST_DB_DIR --yes"
    test_passed
}

test_compare_with_changes() {
    local test_number="$1"
    print_test_header "$test_number" "COMPARE WITH CHANGES"
    
    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Source database path: $TEST_DB_DIR"
    log_info "Replica database path: $replica_dir"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Add a new asset to the original database to create a difference
    local new_test_file="$TEST_FILES_DIR/test.webp"
    local webp_add_output
    invoke_command "Add new asset to original database" "$(get_cli_command) add --db $TEST_DB_DIR $new_test_file --verbose --yes" 0 "webp_add_output"
    
    # Validate the WEBP asset in the database
    validate_database_assets "$TEST_DB_DIR" "$new_test_file" "image/webp" "image" "$webp_add_output"
    
    # Test comparison between original and replica (should show differences after adding new asset)
    local compare_output
    invoke_command "Compare original database with replica after changes" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison detects the specific number of differences (new asset creates 8 differences)
    expect_output_string "$compare_output" "Databases have 3 differences" "Databases have 3 differences after adding new asset"
    test_passed
}

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
    invoke_command "Replicate changes to replica" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes --force" 0 "replication_output"
    
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

test_cannot_create_over_existing() {
    local test_number="$1"
    print_test_header "$test_number" "CANNOT CREATE DATABASE OVER EXISTING"
    
    log_info "Database path: $TEST_DB_DIR"
    
    invoke_command "Fail to create database over existing" "$(get_cli_command) init --db $TEST_DB_DIR --yes" 1
    test_passed
}

test_repair_ok_database() {
    local test_number="$1"
    print_test_header "$test_number" "REPAIR OK DATABASE (NO CHANGES)"
    
    local replica_dir="$TEST_DB_DIR-replica"
    log_info "Database path: $TEST_DB_DIR"
    log_info "Source database path (for repair): $replica_dir"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Run repair on the intact database using replica as source
    local repair_output
    invoke_command "Repair intact database" "$(get_cli_command) repair --db $TEST_DB_DIR --source $replica_dir --yes" 0 "repair_output"
    
    # Check that repair reports no issues found
    expect_output_string "$repair_output" "Database repair completed - no issues found" "Repair of OK database shows no issues"
    expect_output_value "$repair_output" "Repaired:" "0" "No files repaired"
    expect_output_value "$repair_output" "Unrepaired:" "0" "No files unrepaired"
    expect_output_value "$repair_output" "Modified:" "0" "No files modified"
    expect_output_value "$repair_output" "Removed:" "0" "No files removed"
    test_passed
}

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
    invoke_command "Verify database after asset removal" "$(get_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"
    
    # The database should still be consistent
    expect_output_value "$verify_output" "New:" "0" "No new files after removal"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files after removal"
    
    log_success "Asset removal test completed successfully"
    test_passed
}

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
    invoke_command "Verify damaged database" "$(get_cli_command) verify --db $damaged_dir --yes --full" 0 "verify_output"
    
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
    invoke_command "Verify repaired database" "$(get_cli_command) verify --db $damaged_dir --yes" 0 "final_verify_output"
    
    expect_output_string "$final_verify_output" "Database verification passed - all files are intact" "Repaired database verifies successfully"
    
    # Check merkle tree order for repaired database
    check_merkle_tree_order "$damaged_dir/.db/files.dat" "repaired database"
    
    # Clean up damaged database copy
    rm -rf "$damaged_dir"
    log_success "Cleaned up damaged database copy"
    test_passed
}




test_create_database 1
test_view_media_files 2
test_add_png_file 3
test_add_jpg_file 4
test_add_mp4_file 5
test_add_same_file 6
test_add_multiple_files 7
test_add_same_multiple_files 8
test_add_duplicate_images 9
test_database_summary 10
test_database_list 11
test_export_assets 12
test_database_verify 13
test_database_verify_full 14
test_detect_deleted_file 15
test_detect_modified_file 16
test_database_replicate 17
test_verify_replica 18
test_database_replicate_second 19
test_database_compare 20
test_compare_with_changes 21
test_replicate_after_changes 22
test_cannot_create_over_existing 23
test_repair_ok_database 24
test_remove_asset 25
test_repair_damaged_database 26
