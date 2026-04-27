#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_sync_edit_field_reverse() {
    local test_number="$1"
    print_test_header "$test_number" "SYNC DATABASE - EDIT FIELD IN COPY WITH BDB-CLI (REVERSE)"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local original_dir="$test_dir/test-sync-edit-reverse-original"
    local copy_dir="$test_dir/test-sync-edit-reverse-copy"
    log_info "Source database path: $v6_db_dir"
    log_info "Original database path: $original_dir"
    log_info "Copy database path: $copy_dir"
    
    # Hardcoded values from inspecting the v6 database
    local record_id="89171cd9-a652-4047-b869-1154bf2c95a1"
    local field_name="description"
    local field_type="string"
    local new_field_value="Test description edited in copy by bdb-cli"
    
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
    
    # Edit a field in the COPY database using bdb-cli (inverse of the original test)
    log_info "Editing field '$field_name' in record '$record_id' in COPY database using bdb-cli"
    local edit_output
    invoke_command "Edit field in copy using bdb-cli" "$(get_bdb_command) edit $copy_dir/.db/bson metadata $record_id $field_name $field_type \"$new_field_value\"" 0 "edit_output"
    
    # Verify the edit was successful
    expect_output_string "$edit_output" "Successfully updated field" "Field edit was successful"
    
    # Verify the field was actually changed by reading it back from copy
    log_info "Verifying field was changed in copy by reading record back"
    local verify_record_output
    verify_record_output=$($(get_bdb_command) record $copy_dir/.db/bson metadata $record_id --all 2>&1)
    local record_exit_code=$?
    
    if [ $record_exit_code -ne 0 ]; then
        log_error "Failed to read record from copy to verify edit"
        echo "$verify_record_output"
        exit 1
    fi
    
    if echo "$verify_record_output" | grep -q "$new_field_value"; then
        log_success "Copy record contains the new field value"
    else
        log_error "Copy record does not contain the new field value: $new_field_value"
        echo "Record output:"
        echo "$verify_record_output"
        exit 1
    fi
    
    # Get root hashes and verify they are now different
    log_info "Verifying original and copy now have different root hashes after edit in copy"
    invoke_command "Get original database root hash (unchanged)" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get copy database root hash after edit" "$(get_cli_command) root-hash --db $copy_dir --yes" 0 "copy_hash_output"
    
    local original_hash_before_sync=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local copy_hash_after=$(echo "$copy_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    # Verify the copy database root hash changed after the edit
    if [ "$copy_hash" != "$copy_hash_after" ]; then
        log_success "Copy database root hash changed after edit"
        log_info "Copy hash before edit: $copy_hash"
        log_info "Copy hash after edit: $copy_hash_after"
    else
        log_error "Copy database root hash should have changed after edit but it did not"
        log_error "Hash before edit: $copy_hash"
        log_error "Hash after edit: $copy_hash_after"
        exit 1
    fi
    
    if [ "$original_hash_before_sync" != "$copy_hash_after" ]; then
        log_success "Original and copy databases have different root hashes after editing field in copy"
        log_info "Original hash: $original_hash_before_sync"
        log_info "Copy hash: $copy_hash_after"
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
    
    # Use sync command to synchronize databases (should pull changes from copy to original)
    log_info "Using sync command to synchronize databases (bidirectional - should pull from copy to original)"
    local sync_output
    invoke_command "Sync databases (copy changes to original)" "$(get_cli_command) sync --db $original_dir --dest $copy_dir --yes" 0 "sync_output"
    
    # Verify sync completed
    expect_output_string "$sync_output" "Sync completed successfully" "Sync completed successfully"
    
    # Verify the original database now has the edited field
    log_info "Verifying original database now has the edited field from copy"
    local original_record_output
    original_record_output=$($(get_bdb_command) record $original_dir/.db/bson metadata $record_id --all 2>&1)
    local original_record_exit_code=$?
    
    if [ $original_record_exit_code -ne 0 ]; then
        log_error "Failed to read record from original to verify sync"
        echo "$original_record_output"
        exit 1
    fi
    
    if echo "$original_record_output" | grep -q "$new_field_value"; then
        log_success "Original database contains the new field value from copy"
    else
        log_error "Original database does not contain the new field value: $new_field_value"
        echo "Record output:"
        echo "$original_record_output"
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
    check_merkle_tree_order "$original_dir/.db/files.dat" "sync edit reverse original database"
    check_merkle_tree_order "$copy_dir/.db/files.dat" "sync edit reverse copy database"
    
    # Clean up temporary databases
    rm -rf "$original_dir"
    rm -rf "$copy_dir"
    log_success "Cleaned up temporary sync edit reverse test databases"
    test_passed
}


test_sync_edit_field_reverse "${1:-38}"
