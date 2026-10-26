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

    # The whole listing is compared, character for character, so a change to a column width, the
    # separator or the path printed fails the test.
    local zig_dbs_list
    invoke_command "List the databases with the Zig CLI" "$(get_zig_cli_command) -q dbs list" 0 "zig_dbs_list"
    local expected_dbs_list
    expected_dbs_list="$(
        printf '\n'
        printf '%-26s%s\n' "Name" "Path"
        printf '%s\n' "──────────────────────────────────────────────────────────────────────"
        printf '%-26s%s\n' "smoke-db" "$smoke_db_path"
    )"
    expect_value "$zig_dbs_list" "$expected_dbs_list" "The database list shows the seeded entry"

    test_passed
}

test_dbs_add_and_list "${1:-46}"
