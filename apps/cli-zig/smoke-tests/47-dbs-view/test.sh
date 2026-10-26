#!/bin/bash
DESCRIPTION="psi dbs view shows name path and secret IDs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_view() {
    local test_number="$1"
    print_test_header "$test_number" "DBS VIEW"

    local view_db_path="$TEST_TMP_DIR/view-db"

    seed_databases_config "[{\"name\":\"view-db\",\"description\":\"A test database\",\"path\":\"$view_db_path\",\"encryptionKey\":\"enc00001\",\"s3Key\":\"s3test01\"}]"

    local dbs_output
    invoke_command "View database entry" "$(get_zig_cli_command) dbs view --name view-db" 0 "dbs_output"

    expect_output_string "$dbs_output" "view-db" "Name appears in view output"
    expect_output_string "$dbs_output" "$view_db_path" "Path appears in view output"
    expect_output_string "$dbs_output" "enc00001" "Encryption key ID appears in view output"
    expect_output_string "$dbs_output" "s3test01" "S3 credential ID appears in view output"

    # The whole entry is compared, character for character, so a missing field, a changed label or
    # a change to the alignment fails the test.
    local zig_quiet_output
    invoke_command "View the database entry quietly with the Zig CLI" "$(get_zig_cli_command) -q dbs view --name view-db --yes" 0 "zig_quiet_output"
    local expected_view_output
    expected_view_output="$(
        printf '\n'
        printf '%s\n' "Database Entry"
        printf '%s\n' "──────────────────────────────────────────────────"
        printf '%-13s%s\n' "Name:" "view-db"
        printf '%-13s%s\n' "Description:" "A test database"
        printf '%-13s%s\n' "Path:" "$view_db_path"
        printf '%-13s%s\n' "S3 Creds:" "s3test01"
        printf '%-13s%s\n' "Encryption:" "enc00001"
        printf '%-13s%s\n' "Geocoding:" "(none)"
    )"
    expect_value "$zig_quiet_output" "$expected_view_output" "The database view shows every field of the entry"

    test_passed
}

test_dbs_view "${1:-47}"
