#!/bin/bash
DESCRIPTION="Add a secret to OS keychain, delete it, verify it is gone from list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_delete() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT DELETE"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-delete"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add keep-secret to keychain" "$(get_cli_command) secrets add --yes --name keep-secret --type plain --value keep-me" 0
    invoke_command "Add delete-secret to keychain" "$(get_cli_command) secrets add --yes --name delete-secret --type plain --value delete-me" 0

    invoke_command "Delete keychain secret" "$(get_cli_command) secrets remove --name delete-secret --yes" 0

    local list_output
    invoke_command "List secrets after keychain delete" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "keep-secret" "Remaining keychain secret still present"
    expect_output_string "$list_output" "delete-secret" "Deleted keychain secret is absent" false

    eval "$(get_cli_command) secrets remove --name keep-secret --yes" 2>/dev/null || true
    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_delete "${1:-62}"
