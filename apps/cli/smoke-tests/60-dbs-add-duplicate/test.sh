#!/bin/bash
DESCRIPTION="Adding a database with a duplicate name fails with error"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_add_duplicate() {
    local test_number="$1"
    print_test_header "$test_number" "DBS ADD DUPLICATE"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/dbs-add-duplicate"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    local dup_db_path_1="$test_dir/dup-db-1"
    local dup_db_path_2="$test_dir/dup-db-2"

    invoke_command "Add database first time" "$(get_cli_command) dbs add --yes --name dup-db --path $dup_db_path_1" 0

    local error_output
    invoke_command "Add database with same name fails" "$(get_cli_command) dbs add --yes --name dup-db --path $dup_db_path_2" 1 "error_output"

    expect_output_string "$error_output" "already exists" "Error message mentions already exists"

    local dbs_output
    invoke_command "List databases" "$(get_cli_command) dbs list" 0 "dbs_output"
    expect_output_string "$dbs_output" "$dup_db_path_1" "Original path still present"
    expect_output_string "$dbs_output" "$dup_db_path_2" "Duplicate path absent" false

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_dbs_add_duplicate "${1:-66}"
