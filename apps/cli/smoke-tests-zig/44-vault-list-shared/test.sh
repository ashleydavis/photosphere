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

    local zig_vault_list
    local ts_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    invoke_command "List the vault with the TypeScript CLI" "$(get_cli_command) secrets list" 0 "ts_vault_list"
    expect_value "$ts_vault_list" "$zig_vault_list" "The TypeScript CLI reads the vault the Zig CLI wrote"

    test_passed
}


test_vault_list_shared "${1:-44}"
