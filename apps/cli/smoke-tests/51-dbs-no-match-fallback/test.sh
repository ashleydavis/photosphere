#!/bin/bash
DESCRIPTION="No databases.json match falls back to existing flow"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_no_match_fallback() {
    local test_number="$1"
    print_test_header "$test_number" "DBS NO MATCH FALLBACK"

    local test_dir="$TEST_TMP_DIR/dbs-no-match"
    local db_dir="$test_dir/db"

    rm -rf "$test_dir"
    mkdir -p "$test_dir"

    # Create a plain (unencrypted) database.
    invoke_command "Init plain database" "$(get_cli_command) init --db \"$db_dir\" --yes" 0

    invoke_command "Add PNG to plain database" "$(get_cli_command) add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes" 0

    # Clear databases.json so there's no match.
    seed_databases_config '[]'

    # Summary should still work using existing manual config flows.
    local summary_output
    invoke_command "Summary with no databases.json match" "$(get_cli_command) summary --db \"$db_dir\" --yes" 0 "summary_output"

    expect_output_string "$summary_output" "1" "Summary shows at least 1 asset"

    test_passed
}

# -----------------------------------------------------------------------------
# Secrets & dbs non-interactive CLI smoke tests
# -----------------------------------------------------------------------------


test_dbs_no_match_fallback "${1:-51}"
