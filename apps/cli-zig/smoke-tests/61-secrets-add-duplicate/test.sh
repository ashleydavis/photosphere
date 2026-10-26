#!/bin/bash
DESCRIPTION="Adding a secret with a duplicate name fails with error"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_secrets_add_duplicate() {
    local test_number="$1"
    print_test_header "$test_number" "SECRETS ADD DUPLICATE"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-add-duplicate"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add secret first time" "$(get_zig_cli_command) secrets add --yes --name dup-secret --type plain --value first" 0

    local error_output
    invoke_command "Add secret with same name fails" "$(get_zig_cli_command) secrets add --yes --name dup-secret --type plain --value second" 1 "error_output"

    expect_output_string "$error_output" "already exists" "Error message mentions already exists"

    # The whole listing is compared, character for character, so the failed add must leave exactly
    # one secret of that name in the vault.
    local zig_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    local expected_vault_list
    expected_vault_list="$(
        printf '\n'
        printf '%-41s%-21s%s\n' "Name" "Type" "Value"
        printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
        printf '%-41s%-21s%s\n' "dup-secret" "plain" "****"
    )"
    expect_value "$zig_vault_list" "$expected_vault_list" "The vault list shows the secret once"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_secrets_add_duplicate "${1:-67}"
