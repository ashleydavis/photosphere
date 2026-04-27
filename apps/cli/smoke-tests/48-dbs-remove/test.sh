#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_remove() {
    local test_number="$1"
    print_test_header "$test_number" "DBS REMOVE"

    seed_databases_config '[{"name":"keep-db","description":"","path":"/tmp/keep-db"},{"name":"remove-db","description":"","path":"/tmp/remove-db"}]'

    invoke_command "Remove database entry" "$(get_cli_command) dbs remove --name remove-db --yes" 0

    local dbs_output
    invoke_command "List databases after remove" "$(get_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "remove-db" "remove-db is absent after removal" false
    expect_output_string "$dbs_output" "keep-db" "keep-db still present after removal"

    test_passed
}


test_dbs_remove "${1:-48}"
