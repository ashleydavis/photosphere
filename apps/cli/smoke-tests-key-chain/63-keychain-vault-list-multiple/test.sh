#!/bin/bash
DESCRIPTION="Add multiple secrets to OS keychain and verify all appear in list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_list_multiple() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT LIST MULTIPLE"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-list-multiple"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    # Clean up any leftover secrets from previous runs.
    for secret_name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
        eval "$(get_cli_command) secrets remove --name $secret_name --yes" 2>/dev/null || true
    done

    invoke_command "Add first secret" "$(get_cli_command) secrets add --yes --name list-multi-secret-a --type plain --value value-a" 0
    invoke_command "Add second secret" "$(get_cli_command) secrets add --yes --name list-multi-secret-b --type api-key --value value-b" 0
    invoke_command "Add third secret" "$(get_cli_command) secrets add --yes --name list-multi-secret-c --type s3-credentials --value value-c" 0

    local list_output
    invoke_command "List all secrets" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "list-multi-secret-a" "First secret appears in list"
    expect_output_string "$list_output" "list-multi-secret-b" "Second secret appears in list"
    expect_output_string "$list_output" "list-multi-secret-c" "Third secret appears in list"

    for secret_name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
        eval "$(get_cli_command) secrets remove --name $secret_name --yes" 2>/dev/null || true
    done

    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_list_multiple "${1:-63}"
