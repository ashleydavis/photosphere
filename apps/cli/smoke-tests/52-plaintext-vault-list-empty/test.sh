#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_plaintext_vault_list_empty() {
    local test_number="$1"
    print_test_header "$test_number" "PLAINTEXT VAULT LIST EMPTY"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-list-empty"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    local list_output
    invoke_command "List secrets (empty)" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "No secrets" "Empty vault shows 'No secrets' message"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_plaintext_vault_list_empty "${1:-52}"
