#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_add_cli() {
    local test_number="$1"
    print_test_header "$test_number" "DBS ADD CLI"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/dbs-add-cli"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add database via CLI" "$(get_cli_command) dbs add --yes --name cli-db --path /tmp/cli-db" 0

    local dbs_output
    invoke_command "List databases after add" "$(get_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "cli-db" "Added database appears in list"
    expect_output_string "$dbs_output" "/tmp/cli-db" "Database path appears in list"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_dbs_add_cli "${1:-65}"
