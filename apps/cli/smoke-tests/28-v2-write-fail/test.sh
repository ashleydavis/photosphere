#!/bin/bash
DESCRIPTION="Test write commands fail on v2 database (add, remove)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v2_database_write_commands_fail() {
    local test_number="$1"
    print_test_header "$test_number" "V2 DATABASE WRITE COMMANDS FAIL"
    
    local v2_db_dir="../../test/dbs/v2"
    log_info "Database path: $v2_db_dir"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    
    # Test that add command fails on v2 database with version error
    local add_output
    invoke_command "Run add on v2 database (should fail)" "$(get_cli_command) add $TEST_FILES_DIR/test.png --db $v2_db_dir --yes" 1 "add_output"
    
    # Check that error message mentions upgrade
    expect_output_string "$add_output" "upgrade" "Add command error message suggests running upgrade command"
    log_success "Add command correctly rejected v2 database"
    
    # Test that remove command fails on v2 database with version error
    local remove_output
    invoke_command "Run remove on v2 database (should fail)" "$(get_cli_command) remove 27165d3c-207b-46b6-ab4e-bc92a09aeda3 --db $v2_db_dir --yes" 1 "remove_output"
    
    # Check that error message mentions upgrade
    expect_output_string "$remove_output" "upgrade" "Remove command error message suggests running upgrade command"
    log_success "Remove command correctly rejected v2 database"
    
    test_passed
}


test_v2_database_write_commands_fail "${1:-28}"
