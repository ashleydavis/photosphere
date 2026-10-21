#!/bin/bash
DESCRIPTION=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_key_not_found_message() {
    local test_number="$1"
    local name="key-not-found-message"
    print_test_header "$test_number" "$name"

    local cli
    cli="$(get_zig_cli_command)"

    local test_dir="$TEST_TMP_DIR/$name"
    local db_dir="$test_dir/db"

    mkdir -p "$test_dir"

    invoke_command "Init plain database" "$cli init --db \"$db_dir\" --yes"

    ts_verify "$db_dir"

    local subcommand
    for subcommand in "add --db \"$db_dir\" --key nonexistent-key-xyz --yes /dev/null" \
                      "decrypt --db \"$db_dir\" --key nonexistent-key-xyz --yes" \
                      "upgrade --db \"$db_dir\" --key nonexistent-key-xyz --yes"; do
        local output
        output=$(eval "$cli $subcommand" 2>&1)
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_error "Expected non-zero exit for: psi $subcommand"
            echo "$output"
            test_failed "$name"
        fi
    done

    test_passed
}

test_key_not_found_message "${1:-124}"
