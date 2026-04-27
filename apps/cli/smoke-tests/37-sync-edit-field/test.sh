#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_sync_edit_field() {
    local test_number="$1"
    print_test_header "$test_number" "SYNC DATABASE - EDIT FIELD WITH BDB-CLI"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local original_dir="$test_dir/test-sync-edit-original"
    local copy_dir="$test_dir/test-sync-edit-copy"
    log_info "Source database path: $v6_db_dir"
    log_info "Original database path: $original_dir"
    log_info "Copy database path: $copy_dir"
    
    # Hardcoded values from inspecting the v6 database
    local record_id="89171cd9-a652-4047-b869-1154bf2c95a1"
    local field_name="description"
    local field_type="string"
    local new_field_value="Test description edited by bdb-cli"
    
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
    
    # Edit a field in the original database using bdb-cli
    log_info "Editing field '$field_name' in record '$record_id' using bdb-cli"
    local edit_output
    invoke_command "Edit field using bdb-cli" "$(get_bdb_command) edit $original_dir/.db/bson metadata $record_id $field_name $field_type \"$new_field_value\"" 0 "edit_output"
    
    # Verify the edit was successful
    expect_output_string "$edit_output" "Successfully updated field" "Field edit was successful"
    
    # Verify the field was actually changed by reading it back
    log_info "Verifying field was changed by reading record back"
    local verify_record_output
    verify_record_output=$($(get_bdb_command) record $original_dir/.db/bson metadata $record_id --all 2>&1)
    local record_exit_code=$?
    
    if [ $record_exit_code -ne 0 ]; then
        log_error "Failed to read record to verify edit"
        echo "$verify_record_output"
        exit 1
    fi
    
    if echo "$verify_record_output" | grep -q "$new_field_value"; then
        log_success "Record contains the new field value"
    else
        log_error "Record does not contain the new field value: $new_field_value"
        echo "Record output:"
        echo "$verify_record_output"
        exit 1
    fi
    
    # Get root hashes and verify they are now different
    log_info "Verifying original and copy now have different root hashes after edit"
    invoke_command "Get original database root hash after edit" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash (unchanged)" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_after=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_before_sync=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    # Verify the original database root hash changed after the edit
    if [ "$original_hash" != "$original_hash_after" ]; then
        log_success "Original database root hash changed after edit"
        log_info "Original hash before edit: $original_hash"
        log_info "Original hash after edit: $original_hash_after"
    else
        log_error "Original database root hash should have changed after edit but it did not"
        log_error "Hash before edit: $original_hash"
        log_error "Hash after edit: $original_hash_after"
        exit 1
    fi
    
    if [ "$original_hash_after" != "$copy_hash_before_sync" ]; then
        log_success "Original and copy databases have different root hashes after editing field"
        log_info "Original hash: $original_hash_after"
        log_info "Copy hash: $copy_hash_before_sync"
    else
        log_error "Original and copy databases should have different root hashes but they are the same"
        exit 1
    fi
    
    # Compare databases to detect the difference
    log_info "Comparing databases to detect differences"
    local compare_output
    invoke_command "Compare databases before sync" "$(get_cli_command) compare --db $original_dir --dest $copy_dir --yes" 0 "compare_output"
    
    # Check that comparison detects differences (should show at least 1 difference)
    expect_output_string "$compare_output" "differences" "Comparison detects differences between databases"
    
    # Use sync command to update the copy
    log_info "Using sync command to synchronize databases"
    local sync_output
    invoke_command "Sync original to copy" "$(get_cli_command) sync --db $original_dir --dest $copy_dir --yes" 0 "sync_output"
    
    # Verify sync completed
    expect_output_string "$sync_output" "Sync completed successfully" "Sync completed successfully"
    
    # Verify the copy database now has the edited field
    log_info "Verifying copy database now has the edited field"
    local copy_record_output
    copy_record_output=$($(get_bdb_command) record $copy_dir/.db/bson metadata $record_id --all 2>&1)
    local copy_record_exit_code=$?
    
    if [ $copy_record_exit_code -ne 0 ]; then
        log_error "Failed to read record from copy to verify sync"
        echo "$copy_record_output"
        exit 1
    fi
    
    if echo "$copy_record_output" | grep -q "$new_field_value"; then
        log_success "Copy database contains the new field value"
    else
        log_error "Copy database does not contain the new field value: $new_field_value"
        echo "Record output:"
        echo "$copy_record_output"
        exit 1
    fi
    
    # Get root hashes and verify they are now the same again
    log_info "Verifying original and copy have the same root hash after sync"
    invoke_command "Get original database root hash after sync" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash after sync" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_final=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_final=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash_final" = "$copy_hash_final" ]; then
        log_success "Original and copy databases have the same root hash after sync: $original_hash_final"
    else
        log_error "Original and copy databases have different root hashes after sync"
        log_error "Original hash: $original_hash_final"
        log_error "Copy hash: $copy_hash_final"
        exit 1
    fi
    
    # Compare databases again to verify no differences
    log_info "Comparing databases again to verify no differences"
    local compare_output_final
    invoke_command "Compare databases after sync" "$(get_cli_command) compare --db $original_dir --dest $copy_dir --yes" 0 "compare_output_final"
    
    # Check that comparison shows no differences
    expect_output_string "$compare_output_final" "No differences detected" "No differences detected after sync"
    
    # Verify both databases pass integrity check
    local verify_original_output
    local verify_copy_output
    invoke_command "Verify original database after sync" "$(get_cli_command) verify --db $original_dir --yes" 0 "verify_original_output"
    invoke_command "Verify copy database after sync" "$(get_cli_command) verify --db $copy_dir --yes" 0 "verify_copy_output"
    
    expect_output_string "$verify_original_output" "Database verification passed" "Original database passes verification"
    expect_output_string "$verify_copy_output" "Database verification passed" "Copy database passes verification"
    
    # Check merkle tree order for both databases
    check_merkle_tree_order "$original_dir/.db/files.dat" "sync edit original database"
    check_merkle_tree_order "$copy_dir/.db/files.dat" "sync edit copy database"
    
    # Clean up temporary databases
    rm -rf "$original_dir"
    rm -rf "$copy_dir"
    log_success "Cleaned up temporary sync edit test databases"
    test_passed
}


test_sync_edit_field "${1:-37}"
