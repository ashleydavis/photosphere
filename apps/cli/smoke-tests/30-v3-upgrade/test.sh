#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v3_database_upgrade() {
    local test_number="$1"
    print_test_header "$test_number" "V3 DATABASE UPGRADE TO V6"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v3_db_dir="../../test/dbs/v3"
    local temp_v3_dir="$test_dir/test-v3-upgrade"
    log_info "Source database path: $v3_db_dir"
    log_info "Temporary upgrade database path: $temp_v3_dir"
    
    # Check that v3 database exists
    check_exists "$v3_db_dir" "V3 test database directory"
    
    # Create a copy of v3 database for upgrade testing
    log_info "Creating copy of v3 database for upgrade testing"
    rm -rf "$temp_v3_dir"
    log_info "Copying database: cp -r \"$v3_db_dir\" \"$temp_v3_dir\""
    cp -r "$v3_db_dir" "$temp_v3_dir"
    
    # Test upgrade command on v3 database
    local upgrade_output
    invoke_command "Upgrade v3 database to v6" "$(get_cli_command) upgrade --db $temp_v3_dir --yes" 0 "upgrade_output"
    
    # Check that upgrade was successful
    expect_output_string "$upgrade_output" "Database upgraded successfully to version 6" "Upgrade completed successfully"
    
    # Verify the upgraded database is now version 6
    local summary_output
    invoke_command "Check upgraded database version" "$(get_cli_command) summary --db $temp_v3_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 6" "Upgraded database is now version 6"
    
    # Test that verify command now works on upgraded database
    local verify_output
    invoke_command "Verify upgraded database" "$(get_cli_command) verify --db $temp_v3_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "Upgraded database verifies successfully"
    
    # Check merkle tree order for upgraded database
    check_merkle_tree_order "$temp_v3_dir/.db/files.dat" "upgraded v3 database"
    
    # Clean up temporary database
    rm -rf "$temp_v3_dir"
    log_success "Cleaned up temporary v3 upgrade database"
    test_passed
}


test_v3_database_upgrade "${1:-30}"
