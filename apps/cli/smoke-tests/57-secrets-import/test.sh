#!/bin/bash
DESCRIPTION="Import a PEM key pair and verify via list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_secrets_import() {
    local test_number="$1"
    print_test_header "$test_number" "SECRETS IMPORT"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-import"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    local key_dir="$test_dir/keys"
    mkdir -p "$key_dir"

    # Generate a PEM private key using openssl.
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key_dir/test-import.key" 2>/dev/null

    invoke_command "Import key" "$(get_cli_command) secrets import --yes --private-key \"$key_dir/test-import.key\"" 0

    local list_output
    invoke_command "List secrets after import" "$(get_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "test-import" "Imported key appears in secrets list"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_secrets_import "${1:-57}"
