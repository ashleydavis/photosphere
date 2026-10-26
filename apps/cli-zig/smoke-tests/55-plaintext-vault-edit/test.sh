#!/bin/bash
DESCRIPTION="Edit a plaintext vault secret with --yes and verify updated value"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_plaintext_vault_edit() {
    local test_number="$1"
    print_test_header "$test_number" "PLAINTEXT VAULT EDIT"

    # Use an isolated vault and config for this test.
    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-edit"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    seed_vault_secret "edit-secret" "plain" "original-value"

    invoke_command "Edit secret via CLI" "$(get_zig_cli_command) secrets edit --name edit-secret --yes --value updated-value" 0

    local view_output
    invoke_command "View secret after edit" "$(get_zig_cli_command) secrets view --name edit-secret --yes" 0 "view_output"

    expect_output_string "$view_output" "updated-value" "Secret value updated after edit"

    invoke_command "Rename secret via CLI" "$(get_zig_cli_command) secrets edit --name edit-secret --yes --new-name renamed-secret" 0

    local list_output
    invoke_command "List secrets after rename" "$(get_zig_cli_command) secrets list" 0 "list_output"

    expect_output_string "$list_output" "renamed-secret" "Renamed secret appears in list"
    expect_output_string "$list_output" "edit-secret" "Old secret name gone after rename" "false"

    # The whole listing is compared, character for character, so the renamed secret has to be the
    # only one, with its type kept and its value masked.
    local zig_vault_list
    invoke_command "List the vault with the Zig CLI" "$(get_zig_cli_command) secrets list" 0 "zig_vault_list"
    local expected_vault_list
    expected_vault_list="$(
        printf '\n'
        printf '%-41s%-21s%s\n' "Name" "Type" "Value"
        printf '%s\n' "────────────────────────────────────────────────────────────────────────────────"
        printf '%-41s%-21s%s\n' "renamed-secret" "plain" "****"
    )"
    expect_value "$zig_vault_list" "$expected_vault_list" "The vault list shows only the renamed secret"

    # Restore shared vault and config.
    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}


test_plaintext_vault_edit "${1:-55}"
