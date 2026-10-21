#!/bin/bash
DESCRIPTION="Create DB with encryption and generated key"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
trap cleanup_and_show_summary EXIT

test_init_encrypted() {
    local test_number="$1"
    local name="init-encrypted"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/db"
    local key_name="init-enc-key"

    mkdir -p "$test_dir"

    invoke_command "Init encrypted database" "$cli init --db \"$db_dir\" --key \"$key_name\" --generate-key --yes"

    ts_verify "$db_dir" --key "$key_name"

    if [ ! -d "$db_dir/.db" ] || [ ! -f "$db_dir/.db/files.dat" ] || [ ! -f "$db_dir/.db/encryption.pub" ]; then
        log_error "Encrypted database metadata not created correctly in $db_dir"
        test_failed "$name"
    fi

    test_passed
}

test_init_encrypted "${1:-105}"
