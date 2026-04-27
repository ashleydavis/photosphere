#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_sync_delete_asset() {
    local test_number="$1"
    print_test_header "$test_number" "SYNC DATABASE - DELETE ASSET AND SYNC BOTH WAYS"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local original_dir="$test_dir/test-sync-delete-original"
    local copy_dir="$test_dir/test-sync-delete-copy"
    log_info "Source database path: $v6_db_dir"
    log_info "Original database path: $original_dir"
    log_info "Copy database path: $copy_dir"
    
    check_exists "$v6_db_dir" "V6 test database directory"
    
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
    
    # Hardcoded asset ID from v5 database
    local test_asset_id="89171cd9-a652-4047-b869-1154bf2c95a1"
    log_info "Using asset ID for deletion test: $test_asset_id"
    
    # Delete the asset from the original database
    log_info "Deleting asset '$test_asset_id' from original database"
    local remove_output
    invoke_command "Remove asset from original database" "$(get_cli_command) remove --db $original_dir $test_asset_id --verbose --yes" 0 "remove_output"
    
    # Check that removal was successful
    expect_output_string "$remove_output" "Successfully removed asset" "Asset removal success message"
    
    # Get root hashes and verify they are now different
    log_info "Verifying original and copy now have different root hashes after deletion"
    invoke_command "Get original database root hash after deletion" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash (unchanged)" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_after=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_before_sync=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    # Verify the original database root hash changed after deletion
    if [ "$original_hash" != "$original_hash_after" ]; then
        log_success "Original database root hash changed after deletion"
        log_info "Original hash before deletion: $original_hash"
        log_info "Original hash after deletion: $original_hash_after"
    else
        log_error "Original database root hash should have changed after deletion but it did not"
        log_error "Hash before deletion: $original_hash"
        log_error "Hash after deletion: $original_hash_after"
        exit 1
    fi
    
    if [ "$original_hash_after" != "$copy_hash_before_sync" ]; then
        log_success "Original and copy databases have different root hashes after deletion"
        log_info "Original hash: $original_hash_after"
        log_info "Copy hash: $copy_hash_before_sync"
    else
        log_error "Original and copy databases should have different root hashes but they are the same"
        exit 1
    fi
    
    # Verify the asset still exists in the copy database
    log_info "Verifying asset still exists in copy database"
    local copy_asset_file="$copy_dir/asset/$test_asset_id"
    if [ ! -f "$copy_asset_file" ]; then
        log_error "Asset file should still exist in copy database but it doesn't: $copy_asset_file"
        exit 1
    else
        log_success "Asset file still exists in copy database (as expected)"
    fi

    # Verify the BSON record has been deleted from the original database
    log_info "Verifying BSON record has been deleted from original database"
    local original_record_output
    original_record_output=$($(get_bdb_command) record $original_dir/.db/bson metadata $test_asset_id --all 2>&1)
    if echo "$original_record_output" | grep -q "Record not found"; then
        log_success "BSON record has been deleted from original database"
    else
        log_error "BSON record should have been deleted from original database but it still exists"
        echo "$original_record_output"
        exit 1
    fi

    # Sync from original to copy (should delete the asset in copy)
    log_info "Syncing from original to copy (should delete asset in copy)"
    local sync_output
    invoke_command "Sync original to copy" "$(get_cli_command) sync --db $original_dir --dest $copy_dir --yes" 0 "sync_output"
    
    # Verify sync completed
    expect_output_string "$sync_output" "Sync completed successfully" "Sync completed successfully"
    
    # Verify the BSON record has been deleted from the copy database after sync
    log_info "Verifying BSON record has been deleted from copy database after sync"
    local copy_record_output
    copy_record_output=$($(get_bdb_command) record $copy_dir/.db/bson metadata $test_asset_id --all 2>&1)
    if echo "$copy_record_output" | grep -q "Record not found"; then
        log_success "BSON record has been deleted from copy database"
    else
        log_error "BSON record should have been deleted from copy database but it still exists"
        echo "$copy_record_output"
        exit 1
    fi

    # Verify the asset has been deleted from the copy database
    log_info "Verifying asset has been deleted from copy database after sync"
    if [ -f "$copy_asset_file" ]; then
        log_error "Asset file should have been deleted from copy database but it still exists: $copy_asset_file"
        exit 1
    else
        log_success "Asset file has been deleted from copy database"
    fi

    # Verify the BSON record has not been restored in the original database after sync
    log_info "Verifying BSON record has not been restored in original database after sync"
    local original_record_after_sync_output
    original_record_after_sync_output=$($(get_bdb_command) record $original_dir/.db/bson metadata $test_asset_id --all 2>&1)
    if echo "$original_record_after_sync_output" | grep -q "Record not found"; then
        log_success "BSON record remains deleted from original database after sync"
    else
        log_error "BSON record was restored in original database after sync but should remain deleted"
        echo "$original_record_after_sync_output"
        exit 1
    fi

    # Get root hashes and verify they are now the same again (sync is bidirectional)
    log_info "Verifying original and copy have the same root hash after bidirectional sync"
    invoke_command "Get original database root hash after bidirectional sync" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash after bidirectional sync" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_final=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_final=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash_final" = "$copy_hash_final" ]; then
        log_success "Original and copy databases have the same root hash after bidirectional sync: $original_hash_final"
    else
        log_error "Original and copy databases have different root hashes after bidirectional sync"
        log_error "Original hash: $original_hash_final"
        log_error "Copy hash: $copy_hash_final"
        exit 1
    fi
    
    # Check merkle tree order for both databases
    check_merkle_tree_order "$original_dir/.db/files.dat" "sync delete original database"
    check_merkle_tree_order "$copy_dir/.db/files.dat" "sync delete copy database"
    
    # Clean up temporary databases
    rm -rf "$original_dir"
    rm -rf "$copy_dir"
    log_success "Cleaned up temporary sync delete test databases"
    test_passed
}


test_sync_delete_asset "${1:-39}"
