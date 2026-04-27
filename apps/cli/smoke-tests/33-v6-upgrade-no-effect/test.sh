#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v6_database_upgrade_no_effect() {
    local test_number="$1"
    print_test_header "$test_number" "V6 DATABASE UPGRADE HAS NO EFFECT"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local temp_v6_dir="$test_dir/test-v6-upgrade"
    log_info "Source database path: $v6_db_dir"
    log_info "Temporary upgrade database path: $temp_v6_dir"
    
    check_exists "$v6_db_dir" "V6 test database directory"
    
    log_info "Creating copy of v6 database for upgrade testing"
    rm -rf "$temp_v6_dir"
    log_info "Copying database: cp -r \"$v6_db_dir\" \"$temp_v6_dir\""
    cp -r "$v6_db_dir" "$temp_v6_dir"
    
    local upgrade_output
    invoke_command "Upgrade v6 database (should be no-op)" "$(get_cli_command) upgrade --db $temp_v6_dir --yes" 0 "upgrade_output"
    
    expect_output_string "$upgrade_output" "Database is already at the latest version (6)" "Upgrade reports database is already current"
    
    local summary_output
    invoke_command "Check database version after upgrade" "$(get_cli_command) summary --db $temp_v6_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 6" "Database is still version 6"
    
    local verify_output
    invoke_command "Verify v6 database after upgrade" "$(get_cli_command) verify --db $temp_v6_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "V6 database verifies successfully after upgrade"
    
    check_merkle_tree_order "$temp_v6_dir/.db/files.dat" "v6 upgrade test database"
    
    rm -rf "$temp_v6_dir"
    log_success "Cleaned up temporary v6 upgrade database"
    test_passed
}


test_v6_database_upgrade_no_effect "${1:-33}"
