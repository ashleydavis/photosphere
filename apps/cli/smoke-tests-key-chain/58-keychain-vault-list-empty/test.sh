#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_keychain_vault_list_empty() {
    local test_number="$1"
    print_test_header "$test_number" "KEYCHAIN VAULT LIST EMPTY"

    local saved_vault_type="$PHOTOSPHERE_VAULT_TYPE"
    export PHOTOSPHERE_VAULT_TYPE="keychain"

    local test_dir="$TEST_TMP_DIR/keychain-vault-list-empty"
    rm -rf "$test_dir"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"

    # Clear any leftover test secrets from previous runs (keychain is OS-global).
    for secret_name in keychain-test-secret view-secret edit-secret renamed-secret keep-secret delete-secret; do
        eval "$(get_cli_command) secrets remove --name $secret_name --yes" 2>/dev/null || true
    done

    invoke_command "List secrets (keychain)" "$(get_cli_command) secrets list" 0

    export PHOTOSPHERE_VAULT_TYPE="$saved_vault_type"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    test_passed
}


test_keychain_vault_list_empty "${1:-58}"
