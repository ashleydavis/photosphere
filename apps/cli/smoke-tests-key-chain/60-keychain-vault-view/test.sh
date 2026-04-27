#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_view() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT VIEW"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-view"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add view-secret to keychain" "$(get_cli_command) secrets add --yes --name view-secret --type plain --value my-secret-value" 0

    local view_output
    invoke_command "View keychain secret" "$(get_cli_command) secrets view --name view-secret --yes" 0 "view_output"

    expect_output_string "$view_output" "view-secret" "Secret name appears in view output"
    expect_output_string "$view_output" "plain" "Secret type appears in view output"
    expect_output_string "$view_output" "my-secret-value" "Secret value appears in view output"

    eval "$(get_cli_command) secrets remove --name view-secret --yes" 2>/dev/null || true
    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_view "${1:-60}"
