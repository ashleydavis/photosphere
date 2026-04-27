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
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    invoke_command "Add secret first time" "$(get_cli_command) secrets add --yes --name dup-secret --type plain --value first" 0

    local error_output
    invoke_command "Add secret with same name fails" "$(get_cli_command) secrets add --yes --name dup-secret --type plain --value second" 1 "error_output"

    expect_output_string "$error_output" "already exists" "Error message mentions already exists"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_secrets_add_duplicate "${1:-67}"
