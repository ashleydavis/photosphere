#!/bin/bash
DESCRIPTION="Init encrypted DB and ensure key file is created and cleaned up"

# The encrypted suite this came from ran this test twice in a row against one vault, so the second
# run met a vault that already held the key the first run generated. This test does the same: the
# body runs twice against this test's vault, the second time in a second database directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

#
# Creates an encrypted database in the given directory with a generated vault key and checks it.
# Usage: init_with_generated_key <name> <db_dir>
#
init_with_generated_key() {
    local name="$1"
    local db_dir="$2"

    local cli
    cli="$(get_zig_cli_command)"

    local key_name="init-gen-key"

    invoke_command "Init encrypted database with generated vault key" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    if [ ! -f "$db_dir/.db/encryption.pub" ]; then
        log_error "Expected encryption.pub not found after init with generated key"
        test_failed "$name"
    fi
}

test_init_generate_key_file() {
    local test_number="$1"
    local name="init-generate-key-file"
    print_test_header "$test_number" "$name"

    local test_dir="$TEST_TMP_DIR/$name"

    mkdir -p "$test_dir"

    log_info "First run: the vault holds no key yet"
    init_with_generated_key "$name" "$test_dir/db"

    log_info "Second run: the vault already holds the key the first run generated"
    init_with_generated_key "$name" "$test_dir/db-2"

    test_passed
}

test_init_generate_key_file "${1:-106}"
