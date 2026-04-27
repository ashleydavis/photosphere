#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v5_database_upgrade() {
    local test_number="$1"
    print_test_header "$test_number" "V5 DATABASE UPGRADE TO V6"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v5_db_dir="../../test/dbs/v5"
    local temp_v5_dir="$test_dir/test-v5-upgrade"
    log_info "Source database path: $v5_db_dir"
    log_info "Temporary upgrade database path: $temp_v5_dir"
    
    check_exists "$v5_db_dir" "V5 test database directory"
    
    log_info "Creating copy of v5 database for upgrade testing"
    rm -rf "$temp_v5_dir"
    log_info "Copying database: cp -r \"$v5_db_dir\" \"$temp_v5_dir\""
    cp -r "$v5_db_dir" "$temp_v5_dir"
    
    local upgrade_output
    invoke_command "Upgrade v5 database to v6" "$(get_cli_command) upgrade --db $temp_v5_dir --yes" 0 "upgrade_output"
    
    expect_output_string "$upgrade_output" "Database upgraded successfully to version 6" "Upgrade completed successfully"
    
    local summary_output
    invoke_command "Check database version after upgrade" "$(get_cli_command) summary --db $temp_v5_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 6" "Upgraded database is now version 6"
    
    local verify_output
    invoke_command "Verify upgraded database" "$(get_cli_command) verify --db $temp_v5_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "Upgraded database verifies successfully"
    
    check_merkle_tree_order "$temp_v5_dir/.db/files.dat" "upgraded v5 database"
    
    rm -rf "$temp_v5_dir"
    log_success "Cleaned up temporary v5 upgrade database"
    test_passed
}


test_v5_database_upgrade "${1:-32}"
