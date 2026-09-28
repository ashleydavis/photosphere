#!/bin/bash
DESCRIPTION="psi secrets clear --yes removes all secrets from the vault"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_secrets_clear() {
    local test_number="$1"
    print_test_header "$test_number" "SECRETS CLEAR"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-clear"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_vault_secret "clear-secret-one" "plain" "value-one"
    seed_vault_secret "clear-secret-two" "plain" "value-two"

    invoke_command "Clear all secrets" "$(get_zig_cli_command) secrets clear --yes" 0

    local list_output
    invoke_command "List secrets after clear" "$(get_zig_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "clear-secret-one" "clear-secret-one is absent after clear" false
    expect_output_string "$list_output" "clear-secret-two" "clear-secret-two is absent after clear" false
    expect_output_string "$list_output" "No secrets" "Empty message shown after clear"

    local zig_vault_list
    local ts_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    invoke_command "List the vault with the TypeScript CLI" "$(get_cli_command) secrets list" 0 "ts_vault_list"
    expect_value "$ts_vault_list" "$zig_vault_list" "The TypeScript CLI reads the vault the Zig CLI wrote"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}

# Reset function to clean up test artifacts

test_secrets_clear "${1:-69}"
