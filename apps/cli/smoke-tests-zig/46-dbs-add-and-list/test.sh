#!/bin/bash
DESCRIPTION="Seed database entry and verify psi dbs list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_add_and_list() {
    local test_number="$1"
    print_test_header "$test_number" "DBS ADD AND LIST"

    local smoke_db_path="$TEST_TMP_DIR/smoke-db"

    # Seed a database entry directly.
    seed_databases_config "[{\"name\":\"smoke-db\",\"description\":\"Smoke test database\",\"path\":\"$smoke_db_path\"}]"

    local dbs_output
    invoke_command "List databases" "$(get_zig_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "smoke-db" "Database entry appears in dbs list"
    expect_output_string "$dbs_output" "$smoke_db_path" "Database path appears in dbs list"

    local zig_dbs_list
    local ts_dbs_list
    invoke_command "List the databases with the Zig CLI" "$(get_zig_cli_command) -q dbs list" 0 "zig_dbs_list"
    invoke_command "List the databases with the TypeScript CLI" "$(get_cli_command) -q dbs list" 0 "ts_dbs_list"
    expect_value "$ts_dbs_list" "$zig_dbs_list" "The TypeScript CLI reads the database list the Zig CLI wrote"

    test_passed
}

test_dbs_add_and_list "${1:-46}"
