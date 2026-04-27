#!/bin/bash
DESCRIPTION="Test sync from copy to original"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_sync_copy_to_original() {
    local test_number="$1"
    print_test_header "$test_number" "SYNC DATABASE - COPY TO ORIGINAL (REVERSE)"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    # TODO: This test is temporarily disabled in automatic runs until sync bidirectional functionality is working
    # It can still be run individually with: ./smoke-tests.sh 34 or ./smoke-tests.sh sync-copy-to-original
    
    local v6_db_dir="../../test/dbs/v6"
    local original_dir="$test_dir/test-sync-reverse-original"
    local copy_dir="$test_dir/test-sync-reverse-copy"
    local test_file="../../test/test.png"
    log_info "Source database path: $v6_db_dir"
    log_info "Original database path: $original_dir"
    log_info "Copy database path: $copy_dir"
    
    check_exists "$v6_db_dir" "V6 test database directory"
    check_exists "$test_file" "Test image file for reverse sync"
    
    log_info "Creating original database from v6 to $original_dir"
    rm -rf "$original_dir"
    log_info "Copying database: cp -r \"$v6_db_dir\" \"$original_dir\""
    cp -r "$v6_db_dir" "$original_dir"
    
    # Create the copy database using replicate command
    log_info "Creating copy database using replicate command to $copy_dir"
    rm -rf "$copy_dir"
    local replicate_output
    invoke_command "Replicate to create copy" "$(get_cli_command) replicate --db $original_dir --dest $copy_dir --yes --force" 0 "replicate_output"
    
    # Verify both databases exist
    check_exists "$original_dir" "Original database directory"
    check_exists "$copy_dir" "Copy database directory"
    
    # Get root hashes and verify they are the same
    log_info "Verifying original and copy have the same root hash"
    local original_hash_output
    local copy_hash_output
    invoke_command "Get original database root hash" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash" = "$copy_hash" ]; then
        log_success "Original and copy databases have the same root hash: $original_hash"
    else
        log_error "Original and copy databases have different root hashes after replication"
        log_error "Original hash: $original_hash"
        log_error "Copy hash: $copy_hash"
        exit 1
    fi
    
    # Add a new file to the COPY database (reverse direction)
    log_info "Adding new file to copy database (reverse sync test)"
    local add_output
    invoke_command "Add test file to copy database" "$(get_cli_command) add --db $copy_dir $test_file --yes" 0 "add_output"
    
    # Verify file was added
    expect_output_string "$add_output" "Added" "File was added successfully to copy"
    
    # Get root hashes and verify they are now different
    log_info "Verifying original and copy now have different root hashes"
    invoke_command "Get original database root hash (unchanged)" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash after add" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_before_sync=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_after=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash_before_sync" != "$copy_hash_after" ]; then
        log_success "Original and copy databases have different root hashes after adding file to copy"
        log_info "Original hash: $original_hash_before_sync"
        log_info "Copy hash: $copy_hash_after"
    else
        log_error "Original and copy databases should have different root hashes but they are the same"
        exit 1
    fi
    
    # Use sync command to sync from original (which will pull changes from copy)
    # The sync command is bidirectional, so it should sync the file from copy to original
    log_info "Using sync command to synchronize databases (bidirectional)"
    local sync_output
    invoke_command "Sync databases (copy changes to original)" "$(get_cli_command) sync --db $original_dir --dest $copy_dir --yes" 0 "sync_output"
    
    # Verify sync completed
    expect_output_string "$sync_output" "Sync completed successfully" "Sync completed successfully"
    
    # Get root hashes and verify they are now the same again
    log_info "Verifying original and copy have the same root hash after reverse sync"
    invoke_command "Get original database root hash after sync" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash after sync" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_final=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_final=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash_final" = "$copy_hash_final" ]; then
        log_success "Original and copy databases have the same root hash after reverse sync: $original_hash_final"
    else
        log_error "Original and copy databases have different root hashes after sync"
        log_error "Original hash: $original_hash_final"
        log_error "Copy hash: $copy_hash_final"
        exit 1
    fi
    
    # Verify that the original database now has the file that was added to the copy
    log_info "Verifying the original database received the file from copy"
    local original_list_output
    invoke_command "List assets in original database" "$(get_cli_command) list --db $original_dir --yes" 0 "original_list_output"
    
    expect_output_string "$original_list_output" "test.png" "Synced file from copy (test.png) appears in original database"
    expect_output_string "$original_list_output" "test.jpg" "Fixture file (test.jpg) still in original database"
    
    # Verify both databases pass integrity check
    local verify_original_output
    local verify_copy_output
    invoke_command "Verify original database after reverse sync" "$(get_cli_command) verify --db $original_dir --yes" 0 "verify_original_output"
    invoke_command "Verify copy database after reverse sync" "$(get_cli_command) verify --db $copy_dir --yes" 0 "verify_copy_output"
    
    expect_output_string "$verify_original_output" "Database verification passed" "Original database passes verification"
    expect_output_string "$verify_copy_output" "Database verification passed" "Copy database passes verification"
    
    # Check merkle tree order for both databases
    check_merkle_tree_order "$original_dir/.db/files.dat" "reverse sync original database"
    check_merkle_tree_order "$copy_dir/.db/files.dat" "reverse sync copy database"
    
    # Clean up temporary databases
    rm -rf "$original_dir"
    rm -rf "$copy_dir"
    log_success "Cleaned up temporary reverse sync test databases"
    test_passed
}


test_sync_copy_to_original "${1:-36}"
