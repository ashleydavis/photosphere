#!/bin/bash
DESCRIPTION="Test replicate database with deleted asset"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_replicate_with_deleted_asset() {
    local test_number="$1"
    print_test_header "$test_number" "REPLICATE DATABASE WITH DELETED ASSET"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local source_dir="$test_dir/test-replicate-deleted-source"
    local replica_dir="$test_dir/test-replicate-deleted-replica"
    log_info "Source database path: $v6_db_dir"
    log_info "Source database path: $source_dir"
    log_info "Replica database path: $replica_dir"
    
    check_exists "$v6_db_dir" "V6 test database directory"
    
    log_info "Creating source database from v6 to $source_dir"
    rm -rf "$source_dir"
    log_info "Copying database: cp -r \"$v6_db_dir\" \"$source_dir\""
    cp -r "$v6_db_dir" "$source_dir"
    
    check_exists "$source_dir" "Source database directory"
    
    # Hardcoded asset ID from v6 database
    local test_asset_id="89171cd9-a652-4047-b869-1154bf2c95a1"
    log_info "Using asset ID for deletion test: $test_asset_id"
    
    # Delete the asset from the source database
    log_info "Deleting asset '$test_asset_id' from source database"
    local remove_output
    invoke_command "Remove asset from source database" "$(get_cli_command) remove --db $source_dir $test_asset_id --verbose --yes" 0 "remove_output"
    
    # Check that removal was successful
    expect_output_string "$remove_output" "Successfully removed asset" "Asset removal success message"
    
    # Verify the asset files no longer exist in source storage
    local source_asset_file="$source_dir/asset/$test_asset_id"
    local source_display_file="$source_dir/display/$test_asset_id"
    local source_thumb_file="$source_dir/thumb/$test_asset_id"
    
    if [ -f "$source_asset_file" ] || [ -f "$source_display_file" ] || [ -f "$source_thumb_file" ]; then
        log_error "Asset files should have been deleted from source database"
        exit 1
    else
        log_success "Asset files have been deleted from source database"
    fi
    
    # Replicate the database with the deleted asset
    log_info "Replicating database with deleted asset to $replica_dir"
    rm -rf "$replica_dir"
    local replicate_output
    invoke_command "Replicate database with deleted asset" "$(get_cli_command) replicate --db $source_dir --dest $replica_dir --yes --force" 0 "replicate_output"
    
    # Verify replica database exists
    check_exists "$replica_dir" "Replica database directory"
    
    # Verify the asset files do not exist in replica storage
    log_info "Verifying asset files do not exist in replica database"
    local replica_asset_file="$replica_dir/asset/$test_asset_id"
    local replica_display_file="$replica_dir/display/$test_asset_id"
    local replica_thumb_file="$replica_dir/thumb/$test_asset_id"
    
    if [ -f "$replica_asset_file" ] || [ -f "$replica_display_file" ] || [ -f "$replica_thumb_file" ]; then
        log_error "Asset files should not exist in replica database (asset was deleted in source)"
        exit 1
    else
        log_success "Asset files do not exist in replica database (as expected)"
    fi
    
    # Verify original and replica have the same aggregate root hash
    log_info "Verifying original and replica have the same root hash after replication"
    verify_root_hashes_match "$source_dir" "$replica_dir" "source and replica after replication"
    
    # Verify original and replica have the same database ID
    log_info "Verifying database IDs match for source and replica"
    local source_id_output
    local replica_id_output
    invoke_command "Get source database ID" "$(get_cli_command) database-id --db $source_dir --yes" 0 "source_id_output"
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
    
    # Compare databases to verify they are identical
    log_info "Comparing databases to verify they are identical"
    local compare_output
    invoke_command "Compare databases after replication" "$(get_cli_command) compare --db $source_dir --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison shows no differences
    expect_output_string "$compare_output" "No differences detected" "No differences detected after replication"
    
    # Verify both databases pass integrity check
    local verify_source_output
    local verify_replica_output
    invoke_command "Verify source database after replication" "$(get_cli_command) verify --db $source_dir --yes" 0 "verify_source_output"
    invoke_command "Verify replica database after replication" "$(get_cli_command) verify --db $replica_dir --yes" 0 "verify_replica_output"
    
    expect_output_string "$verify_source_output" "Database verification passed" "Source database passes verification"
    expect_output_string "$verify_replica_output" "Database verification passed" "Replica database passes verification"
    
    # Check merkle tree order for both databases
    check_merkle_tree_order "$source_dir/.db/files.dat" "replicate deleted source database"
    check_merkle_tree_order "$replica_dir/.db/files.dat" "replicate deleted replica database"
    
    # Clean up temporary databases
    rm -rf "$source_dir"
    rm -rf "$replica_dir"
    log_success "Cleaned up temporary replicate deleted test databases"
    test_passed
}


test_replicate_with_deleted_asset "${1:-41}"
