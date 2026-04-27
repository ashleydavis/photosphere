#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_v6_database_add_file() {
    local test_number="$1"
    print_test_header "$test_number" "V6 DATABASE ADD FILE AND VERIFY INTEGRITY"
    
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    local v6_db_dir="../../test/dbs/v6"
    local temp_v6_dir="$test_dir/test-v6-add-file"
    local test_file="../../test/test.png"
    log_info "Source database path: $v6_db_dir"
    log_info "Temporary test database path: $temp_v6_dir"
    
    check_exists "$v6_db_dir" "V6 test database directory"
    check_exists "$test_file" "Test image file"
    
    log_info "Creating copy of v6 database for file addition testing"
    rm -rf "$temp_v6_dir"
    log_info "Copying database: cp -r \"$v6_db_dir\" \"$temp_v6_dir\""
    cp -r "$v6_db_dir" "$temp_v6_dir"
    
    local initial_summary_output
    invoke_command "Get initial asset count" "$(get_cli_command) summary --db $temp_v6_dir --yes" 0 "initial_summary_output"
    
    local initial_count
    initial_count=$(echo "$initial_summary_output" | grep -o "Total files:[[:space:]]*[0-9]*" | grep -o "[0-9]*")
    log_info "Initial asset count: $initial_count"
    
    local add_output
    invoke_command "Add test file to v6 database" "$(get_cli_command) add --db $temp_v6_dir $test_file --yes" 0 "add_output"
    
    expect_output_string "$add_output" "Added" "File was added successfully"
    
    local final_summary_output
    invoke_command "Get final asset count" "$(get_cli_command) summary --db $temp_v6_dir --yes" 0 "final_summary_output"
    
    local final_count
    final_count=$(echo "$final_summary_output" | grep -o "Total files:[[:space:]]*[0-9]*" | grep -o "[0-9]*")
    log_info "Final asset count: $final_count"
    
    if [ -z "$final_count" ] || ! [[ "$final_count" =~ ^[0-9]+$ ]]; then
        log_error "Failed to extract final asset count from summary output"
        test_failed "failed to extract final asset count"
        return 1
    fi
    
    local expected_count=$((initial_count + 3))
    if [ "$final_count" -eq "$expected_count" ]; then
        log_success "Asset count increased correctly from $initial_count to $final_count"
    else
        log_error "Asset count mismatch: expected $expected_count, got $final_count"
        test_failed
        return 1
    fi
    
    local verify_output
    invoke_command "Verify database integrity after adding file" "$(get_cli_command) verify --db $temp_v6_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "Database maintains integrity after adding file"
    
    expect_output_string "$final_summary_output" "Database version: 6" "Database is still version 6"
    
    local list_output
    invoke_command "List assets to verify new file" "$(get_cli_command) list --db $temp_v6_dir --yes" 0 "list_output"
    
    expect_output_string "$list_output" "test.jpg" "Test file appears in asset listing"
    
    check_merkle_tree_order "$temp_v6_dir/.db/files.dat" "v6 add-file test database"
    
    rm -rf "$temp_v6_dir"
    log_success "Cleaned up temporary v6 add-file database"
    test_passed
}


test_v6_database_add_file "${1:-34}"
