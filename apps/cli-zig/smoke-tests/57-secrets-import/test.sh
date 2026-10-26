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
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    local key_dir="$test_dir/keys"
    mkdir -p "$key_dir"

    # Generate a PEM private key using openssl.
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key_dir/test-import.key" 2>/dev/null

    invoke_command "Import key" "$(get_zig_cli_command) secrets import --yes --private-key \"$key_dir/test-import.key\"" 0

    local list_output
    invoke_command "List secrets after import" "$(get_zig_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "test-import" "Imported key appears in secrets list"

    # The whole listing is compared, character for character, so the imported key has to be the only
    # secret, named after its file, typed as an encryption key and with its value masked.
    local zig_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    local expected_vault_list
    expected_vault_list="$(
        printf '\n'
        printf '%-41s%-21s%s\n' "Name" "Type" "Value"
        printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
        printf '%-41s%-21s%s\n' "test-import" "encryption-key" "****"
    )"
    expect_value "$zig_vault_list" "$expected_vault_list" "The vault list shows the imported key as an encryption key"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_secrets_import "${1:-57}"
