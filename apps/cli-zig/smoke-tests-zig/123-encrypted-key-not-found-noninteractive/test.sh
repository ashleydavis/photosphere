#!/bin/bash
DESCRIPTION=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_key_not_found_noninteractive() {
    local test_number="$1"
    local name="key-not-found-noninteractive"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/db"

    mkdir -p "$test_dir"

    invoke_command "Init plain database" "$cli init --db \"$db_dir\" --yes"

    verify_database "$db_dir"

    local output
    output=$(eval "$cli compare --key nonexistent-key-xyz --db \"$db_dir\" --dest \"$db_dir\" --yes" 2>&1)
    if [ $? -eq 0 ]; then
        log_error "Expected non-zero exit when key not found in non-interactive mode"
        echo "$output"
        test_failed "$name"
    fi

    if ! echo "$output" | grep -qi "not found"; then
        log_error "Expected 'not found' in output, got: $output"
        test_failed "$name"
    fi

    test_passed
}

test_key_not_found_noninteractive "${1:-123}"
