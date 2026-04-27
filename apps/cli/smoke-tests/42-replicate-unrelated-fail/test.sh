#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_replicate_unrelated_databases_fail() {
    local test_number="$1"
    print_test_header "$test_number" "REPLICATE UNRELATED DATABASES FAIL"
    
    # Get test-specific directory for this test
    local test_dir=$(get_test_dir "$test_number")
    mkdir -p "$test_dir"
    
    # Create two independent databases in test-specific directory
    local first_db_dir="$test_dir/test-unrelated-first"
    local second_db_dir="$test_dir/test-unrelated-second"
    log_info "First database path: $first_db_dir"
    log_info "Second database path: $second_db_dir"
    
    # Clean up any existing test databases
    rm -rf "$first_db_dir"
    rm -rf "$second_db_dir"
    
    # Create first independent database
    log_info "Creating first independent database"
    invoke_command "Initialize first database" "$(get_cli_command) init --db $first_db_dir --yes"
    
    # Create second independent database
    log_info "Creating second independent database"
    invoke_command "Initialize second database" "$(get_cli_command) init --db $second_db_dir --yes"
    
    # Verify both databases exist
    check_exists "$first_db_dir" "First database directory"
    check_exists "$second_db_dir" "Second database directory"
    
    # Get database IDs to confirm they are different
    log_info "Getting database IDs to confirm they are different"
    local first_id_output
    local second_id_output
    invoke_command "Get first database ID" "$(get_cli_command) database-id --db $first_db_dir --yes" 0 "first_id_output"
    invoke_command "Get second database ID" "$(get_cli_command) database-id --db $second_db_dir --yes" 0 "second_id_output"
    
    local first_id=$(echo "$first_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local second_id=$(echo "$second_id_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    log_info "First database ID: $first_id"
    log_info "Second database ID: $second_id"
    
    # Verify they have different IDs
    if [ "$first_id" = "$second_id" ]; then
        log_error "Database IDs should be different but they are the same: $first_id"
        exit 1
    else
        log_success "Database IDs are different (as expected for independent databases)"
    fi
    
    # Try to replicate first database to second database (should fail)
    log_info "Attempting to replicate first database to second database (should fail)"
    local replicate_output
    invoke_command "Replicate unrelated databases (should fail)" "$(get_cli_command) replicate --db $first_db_dir --dest $second_db_dir --yes" 1 "replicate_output"
    
    # Check that the error message contains the expected text
    expect_output_string "$replicate_output" "different ID than the source database" "Error message mentions different database IDs"
    expect_output_string "$replicate_output" "Source database ID: $first_id" "Error message shows source database ID"
    expect_output_string "$replicate_output" "Destination database ID: $second_id" "Error message shows destination database ID"
    expect_output_string "$replicate_output" "not related to the source database" "Error message indicates databases are not related"
    
    log_success "Replication correctly failed between unrelated databases"
    
    # Preserve temporary databases for inspection
    log_info "Temporary databases preserved for inspection in test directory: $test_dir"
    log_info "  First database: $first_db_dir"
    log_info "  Second database: $second_db_dir"
    test_passed
}


test_replicate_unrelated_databases_fail "${1:-42}"
