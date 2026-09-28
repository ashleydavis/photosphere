#!/bin/bash
DESCRIPTION="View a plaintext vault secret with --yes and verify output"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_plaintext_vault_view() {
    local test_number="$1"
    print_test_header "$test_number" "PLAINTEXT VAULT VIEW"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-view"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_vault_secret "view-secret" "plain" "my-secret-value"

    local view_output
    invoke_command "View secret" "$(get_zig_cli_command) secrets view --name view-secret --yes" 0 "view_output"

    expect_output_string "$view_output" "view-secret" "Secret name appears in view output"
    expect_output_string "$view_output" "plain" "Secret type appears in view output"
    expect_output_string "$view_output" "my-secret-value" "Secret value appears in view output"

    local zig_vault_list
    local ts_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    invoke_command "List the vault with the TypeScript CLI" "$(get_cli_command) secrets list" 0 "ts_vault_list"
    expect_value "$ts_vault_list" "$zig_vault_list" "The TypeScript CLI reads the vault the Zig CLI wrote"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_plaintext_vault_view "${1:-54}"
