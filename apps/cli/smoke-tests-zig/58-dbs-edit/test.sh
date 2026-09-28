#!/bin/bash
DESCRIPTION="Edit a database entry with --yes and verify rename"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_edit() {
    local test_number="$1"
    print_test_header "$test_number" "DBS EDIT"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/dbs-edit"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_databases_config "[{\"name\":\"edit-db\",\"description\":\"\",\"path\":\"$test_dir/edit-db\"}]"

    invoke_command "Edit database entry" "$(get_zig_cli_command) dbs edit --name edit-db --yes --new-name renamed-db" 0

    local dbs_output
    invoke_command "List databases after edit" "$(get_zig_cli_command) dbs list" 0 "dbs_output"

    expect_output_string "$dbs_output" "renamed-db" "Renamed database appears in list"

    local zig_dbs_list
    local ts_dbs_list
    invoke_command "List the databases with the Zig CLI" "$(get_zig_cli_command) -q dbs list" 0 "zig_dbs_list"
    invoke_command "List the databases with the TypeScript CLI" "$(get_cli_command) -q dbs list" 0 "ts_dbs_list"
    expect_value "$ts_dbs_list" "$zig_dbs_list" "The TypeScript CLI reads the database list the Zig CLI wrote"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}

test_dbs_edit "${1:-64}"
