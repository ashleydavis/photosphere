#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v2_database_readonly_commands() {
    local test_number="$1"
    print_test_header "$test_number" "V2 DATABASE READONLY COMMANDS"
    
    local v2_db_dir="../../test/dbs/v2"
    log_info "Database path: $v2_db_dir"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    check_exists "$v2_db_dir/metadata" "V2 database metadata directory"
    
    # Test that summary command rejects v2 database (only upgrade can load old DBs)
    local summary_output
    invoke_command "Run summary on v2 database (should fail)" "$(get_cli_command) summary --db $v2_db_dir --yes" 1 "summary_output"
    expect_output_string "$summary_output" "upgrade" "Summary on v2 suggests running psi upgrade"
    log_success "Summary correctly rejected v2 database"
    
    # Test that verify command rejects v2 database (only upgrade can load old DBs)
    local verify_output
    invoke_command "Run verify on v2 database (should fail)" "$(get_cli_command) verify --db $v2_db_dir --yes" 1 "verify_output"
    expect_output_string "$verify_output" "upgrade" "Verify on v2 suggests running psi upgrade"
    log_success "Verify correctly rejected v2 database"
    
    test_passed
}


test_v2_database_readonly_commands "${1:-27}"
