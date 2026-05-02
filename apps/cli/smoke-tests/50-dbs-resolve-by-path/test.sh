#!/bin/bash
DESCRIPTION="Resolve database by path with auto-resolved encryption key"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_dbs_resolve_by_path() {
    local test_number="$1"
    print_test_header "$test_number" "DBS RESOLVE BY PATH"

    local test_dir="$TEST_TMP_DIR/dbs-resolve-path"
    local db_dir="$test_dir/db"
    local key_name="dbs-path-enc-key"

    rm -rf "$test_dir"
    mkdir -p "$test_dir"

    # Init an encrypted database with a generated key.
    invoke_command "Init encrypted database" "$(get_cli_command) init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes" 0

    # Add a test file.
    invoke_command "Add PNG to database" "$(get_cli_command) add --db \"$db_dir\" --key \"$key_name\" \"$TEST_FILES_DIR/test.png\" --yes" 0

    # Extract the private key PEM from the CLI vault and store it as a shared secret.
    local cli_key_file="${PHOTOSPHERE_VAULT_DIR}/${key_name}.json"
    local key_value
    key_value=$(bun -e "
        const data = JSON.parse(require('fs').readFileSync('$cli_key_file', 'utf8'));
        process.stdout.write(data.value);
    ")
    seed_vault_secret "enc00002" "encryption-key" "$key_value"

    # Register the database with path and shared encryption key.
    seed_databases_config "[{\"name\":\"resolve-path-db\",\"description\":\"\",\"path\":\"$db_dir\",\"encryptionKey\":\"enc00002\"}]"

    # Summary using the path — should auto-resolve linked encryption key.
    local summary_output
    invoke_command "Summary by path (auto-resolve)" "$(get_cli_command) summary --db \"$db_dir\" --yes" 0 "summary_output"

    expect_output_string "$summary_output" "1" "Summary shows at least 1 asset"

    test_passed
}

test_dbs_resolve_by_path "${1:-50}"
