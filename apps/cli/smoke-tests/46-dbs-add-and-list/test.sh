#!/bin/bash
DESCRIPTION="Seed database entry and verify psi dbs list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_add_and_list() {
    local test_number="$1"
    print_test_header "$test_number" "DBS ADD AND LIST"

    # Seed a database entry directly.
    seed_databases_config '[{"name":"smoke-db","description":"Smoke test database","path":"/tmp/smoke-db"}]'

    local dbs_output
    invoke_command "List databases" "$(get_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "smoke-db" "Database entry appears in dbs list"
    expect_output_string "$dbs_output" "/tmp/smoke-db" "Database path appears in dbs list"

    test_passed
}


test_dbs_add_and_list "${1:-46}"
