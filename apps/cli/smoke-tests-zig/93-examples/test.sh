#!/bin/bash
DESCRIPTION="psi examples prints the usage examples of every command"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_examples() {
    local test_number="$1"
    print_test_header "$test_number" "EXAMPLES"

    local examples_output
    invoke_command "Show the examples with the Zig CLI" "$(get_zig_cli_command) -q examples" 0 "examples_output"

    expect_output_string "$examples_output" "Photosphere CLI Examples" "The examples have their heading"
    expect_output_string "$examples_output" "Database Management:" "The examples are grouped"

    # The commands the examples cover, in the order they are printed.
    local command_name
    for command_name in init add check summary verify find-orphans remove-orphans replicate compare tools info examples bug; do
        expect_output_string "$examples_output" "^  $command_name:$" "The examples cover $command_name"
    done
    expect_output_string "$examples_output" "psi init --db ./photos" "The init examples show a database being created"

    local ts_examples_output
    invoke_command "Show the examples with the TypeScript CLI" "$(get_cli_command) -q examples" 0 "ts_examples_output"
    expect_value "$examples_output" "$ts_examples_output" "The Zig CLI prints the examples the TypeScript CLI prints"

    test_passed
}

test_examples "${1:-93}"
