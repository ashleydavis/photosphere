#!/bin/bash
DESCRIPTION="Upgrade v2 database to v6"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v2_database_upgrade() {
    local test_number="$1"
    print_test_header "$test_number" "V2 DATABASE UPGRADE TO V6"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v2_db_dir="../../test/dbs/v2"
    local temp_v2_dir="$test_dir/test-v2-upgrade"
    log_info "Source database path: $v2_db_dir"
    log_info "Temporary upgrade database path: $temp_v2_dir"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    
    # Create a copy of v2 database for upgrade testing
    log_info "Creating copy of v2 database for upgrade testing"
    rm -rf "$temp_v2_dir"
    log_info "Copying database: cp -r \"$v2_db_dir\" \"$temp_v2_dir\""
    cp -r "$v2_db_dir" "$temp_v2_dir"
    
    # Test upgrade command on v2 database
    local upgrade_output
    invoke_command "Upgrade v2 database to v6" "$(get_cli_command) upgrade --db $temp_v2_dir --yes" 0 "upgrade_output"
    
    # Check that upgrade was successful
    expect_output_string "$upgrade_output" "Database upgraded successfully to version 6" "Upgrade completed successfully"
    
    # Verify the upgraded database is now version 6
    local summary_output
    invoke_command "Check upgraded database version" "$(get_cli_command) summary --db $temp_v2_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 6" "Upgraded database is now version 6"
    
    # Test that verify command now works on upgraded database
    local verify_output
    invoke_command "Verify upgraded database" "$(get_cli_command) verify --db $temp_v2_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "Upgraded database verifies successfully"
    
    # Check merkle tree order for upgraded database
    check_merkle_tree_order "$temp_v2_dir/.db/files.dat" "upgraded v2 database"
    
    # Clean up temporary database
    rm -rf "$temp_v2_dir"
    log_success "Cleaned up temporary v2 upgrade database"
    test_passed
}


test_v2_database_upgrade "${1:-29}"
