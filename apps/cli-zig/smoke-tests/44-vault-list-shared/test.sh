#!/bin/bash
DESCRIPTION="Seed shared secrets in vault and verify vault list"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_vault_list_shared() {
    local test_number="$1"
    print_test_header "$test_number" "VAULT LIST SHARED SECRETS"

    # Seed shared secrets directly in the vault.
    seed_vault_secret "s3test01" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'

    seed_vault_secret "api00001" "api-key" \
        'AIzaFakeKey123'

    local vault_output
    invoke_command "List vault secrets" "$(get_zig_cli_command) secrets list" 0 "vault_output"

    expect_output_string "$vault_output" "s3test01" "S3 credential appears in vault list"
    expect_output_string "$vault_output" "api00001" "API key appears in vault list"

    # The whole listing is compared, character for character, so a change to a column width, the
    # separator, the masking of values or the order of the secrets fails the test.
    local zig_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    local expected_vault_list
    expected_vault_list="$(
        printf '\n'
        printf '%-41s%-21s%s\n' "Name" "Type" "Value"
        printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
        printf '%-41s%-21s%s\n' "s3test01" "s3-credentials" "****"
        printf '%-41s%-21s%s\n' "api00001" "api-key" "****"
    )"
    expect_value "$zig_vault_list" "$expected_vault_list" "The vault list shows both secrets with their values masked"

    test_passed
}


test_vault_list_shared "${1:-44}"
