#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_list_empty() {
    local test_number="$1"
    print_test_header "$test_number" "DBS LIST EMPTY"

    # Ensure no databases.json exists.
    rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.json"

    local dbs_output
    invoke_command "List databases (empty)" "$(get_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "No databases" "Empty list shows 'No databases' message"

    test_passed
}


test_dbs_list_empty "${1:-45}"
