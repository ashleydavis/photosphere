#!/bin/bash
DESCRIPTION="Add a secret to OS keychain and verify it appears in list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_add() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT ADD"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-add"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add secret via CLI to keychain" "$(get_cli_command) secrets add --yes --name keychain-test-secret --type plain --value hello123" 0

    local list_output
    invoke_command "List secrets after keychain add" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "keychain-test-secret" "Added keychain secret appears in list"

    eval "$(get_cli_command) secrets remove --name keychain-test-secret --yes" 2>/dev/null || true
    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_add "${1:-59}"
