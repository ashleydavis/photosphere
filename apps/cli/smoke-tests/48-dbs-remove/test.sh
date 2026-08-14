#!/bin/bash
DESCRIPTION="psi dbs remove --yes removes entry from list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_remove() {
    local test_number="$1"
    print_test_header "$test_number" "DBS REMOVE"

    local keep_db_path="$TEST_TMP_DIR/keep-db"
    local remove_db_path="$TEST_TMP_DIR/remove-db"

    seed_databases_config "[{\"name\":\"keep-db\",\"description\":\"\",\"path\":\"$keep_db_path\"},{\"name\":\"remove-db\",\"description\":\"\",\"path\":\"$remove_db_path\"}]"

    invoke_command "Remove database entry" "$(get_cli_command) dbs remove --name remove-db --yes" 0

    local dbs_output
    invoke_command "List databases after remove" "$(get_cli_command) dbs list" 0 "dbs_output"

    # Both names are matched in the name column, at the start of a line, rather than anywhere in the
    # output. The listing prints each database's path as well as its name, and every path here runs
    # through this test's own temporary directory, which is named after the test: "48-dbs-remove-"
    # followed by six random characters from mktemp. When those two characters happen to be "db" the
    # directory is called "48-dbs-remove-dbXXXX", so keep-db's path contains the string "remove-db"
    # and a search of the whole output finds the name that was just removed. That is about a one in
    # four thousand chance per run, and it failed the macOS arm64 job on 2026-08-14.
    expect_output_string "$dbs_output" "^[[:space:]]*remove-db[[:space:]]" "remove-db is absent after removal" false
    expect_output_string "$dbs_output" "^[[:space:]]*keep-db[[:space:]]" "keep-db still present after removal"

    test_passed
}


test_dbs_remove "${1:-48}"
