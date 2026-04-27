#!/bin/bash
DESCRIPTION="Add a secret to OS keychain, edit its value, verify updated value"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_edit() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT EDIT"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-edit"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add edit-secret to keychain" "$(get_cli_command) secrets add --yes --name edit-secret --type plain --value original-value" 0

    invoke_command "Edit keychain secret value" "$(get_cli_command) secrets edit --name edit-secret --yes --value updated-value" 0

    local view_output
    invoke_command "View secret after edit" "$(get_cli_command) secrets view --name edit-secret --yes" 0 "view_output"

    expect_output_string "$view_output" "updated-value" "Secret value updated after edit"

    invoke_command "Rename keychain secret" "$(get_cli_command) secrets edit --name edit-secret --yes --new-name renamed-secret" 0

    local list_output
    invoke_command "List secrets after rename" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "renamed-secret" "Renamed keychain secret appears in list"
    expect_output_string "$list_output" "edit-secret" "Old keychain secret name gone after rename" "false"

    eval "$(get_cli_command) secrets remove --name renamed-secret --yes" 2>/dev/null || true
    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_edit "${1:-61}"
