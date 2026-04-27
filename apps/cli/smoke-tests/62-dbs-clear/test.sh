#!/bin/bash
DESCRIPTION="psi dbs clear --yes removes all database entries from the list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_clear() {
    local test_number="$1"
    print_test_header "$test_number" "DBS CLEAR"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/dbs-clear"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_databases_config '[{"name":"db-one","description":"","path":"/tmp/db-one"},{"name":"db-two","description":"","path":"/tmp/db-two"}]'

    invoke_command "Clear all databases" "$(get_cli_command) dbs clear --yes" 0

    local dbs_output
    invoke_command "List databases after clear" "$(get_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "db-one" "db-one is absent after clear" false
    expect_output_string "$dbs_output" "db-two" "db-two is absent after clear" false
    expect_output_string "$dbs_output" "No databases" "Empty message shown after clear"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_dbs_clear "${1:-68}"
