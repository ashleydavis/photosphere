#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_plaintext_vault_delete() {
    local test_number="$1"
    print_test_header "$test_number" "PLAINTEXT VAULT DELETE"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-delete"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_vault_secret "keep-secret" "plain" "keep-me"
    seed_vault_secret "delete-secret" "plain" "delete-me"

    invoke_command "Delete secret via CLI" "$(get_cli_command) secrets remove --name delete-secret --yes" 0

    local list_output
    invoke_command "List secrets after delete" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "keep-secret" "Remaining secret still present"
    expect_output_string "$list_output" "delete-secret" "Deleted secret is absent" false

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_plaintext_vault_delete "${1:-56}"
