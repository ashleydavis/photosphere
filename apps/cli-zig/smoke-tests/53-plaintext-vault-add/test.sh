#!/bin/bash
DESCRIPTION="Add a secret to plaintext vault and verify with list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_plaintext_vault_add() {
    local test_number="$1"
    print_test_header "$test_number" "PLAINTEXT VAULT ADD"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-add"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add secret via CLI" "$(get_zig_cli_command) secrets add --yes --name test-secret --type plain --value hello123" 0

    local list_output
    invoke_command "List secrets after add" "$(get_zig_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "test-secret" "Added secret appears in list"

    # The whole listing is compared, character for character, so the added secret has to be the only
    # one, with its type and its value masked.
    local zig_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    local expected_vault_list
    expected_vault_list="$(
        printf '\n'
        printf '%-41s%-21s%s\n' "Name" "Type" "Value"
        printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
        printf '%-41s%-21s%s\n' "test-secret" "plain" "****"
    )"
    expect_value "$zig_vault_list" "$expected_vault_list" "The vault list shows the added secret with its value masked"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_plaintext_vault_add "${1:-53}"
