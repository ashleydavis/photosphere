#!/bin/bash
DESCRIPTION="psi help lists every command, shows the help of one command, and an unknown command fails"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Runs the same arguments through the Zig CLI and the TypeScript CLI, expects the exit code, and
# expects both to print the same. The Zig CLI's output goes into the named variable.
#
expect_same_help() {
    local description="$1"
    local arguments="$2"
    local expected_exit_code="$3"
    local output_var_name="$4"

    local zig_help_output
    invoke_command "$description with the Zig CLI" "$(get_zig_cli_command) -q $arguments" "$expected_exit_code" "zig_help_output"

    local ts_help_output
    invoke_command "$description with the TypeScript CLI" "$(get_cli_command) -q $arguments" "$expected_exit_code" "ts_help_output"
    expect_value "$zig_help_output" "$ts_help_output" "$description: the Zig CLI prints what the TypeScript CLI prints"

    eval "$output_var_name=\"\$zig_help_output\""
}

test_help() {
    local test_number="$1"
    print_test_header "$test_number" "HELP"

    # --- 1. The help of the whole CLI, through the command and through the option. ---

    local help_output
    expect_same_help "Show the help" "help" 0 "help_output"

    expect_output_string "$help_output" "^Usage: psi \[options\] \[command\]$" "The help starts with the usage line"
    local command_name
    for command_name in "add|a" "bug" "check|chk" "compare|cmp" "examples" "export|exp" "find-orphans" "hash" "debug" "info|inf" "init|i" "origin" "set-origin" "consolidate" "list|ls" "news" "remove|rm" "remove-orphans" "repair" "root-hash" "database-id" "replicate|rep" "summary|sum" "sync" "tools" "upgrade" "verify|ver" "version" "encrypt" "decrypt" "secrets|sec" "dbs|d"; do
        expect_output_string "$help_output" "^  $command_name " "The help lists $command_name"
    done
    expect_output_string "$help_output" "Getting help:" "The help says how to get more help"

    local option_help_output
    expect_same_help "Show the help through --help" "--help" 0 "option_help_output"
    expect_value "$option_help_output" "$help_output" "--help prints the same help as the help command"

    # --- 2. The help of one command. ---

    local list_help_output
    expect_same_help "Show the help of the list command" "help list" 0 "list_help_output"
    expect_output_string "$list_help_output" "^Usage: psi list|ls \[options\]$" "The list help has its usage line"
    expect_output_string "$list_help_output" "^  --page-size <size> " "The list help shows its own option"

    local list_option_help_output
    expect_same_help "Show the help of the list command through --help" "list --help" 0 "list_option_help_output"
    expect_value "$list_option_help_output" "$list_help_output" "list --help prints the same help as help list"

    # --- 3. Help for a command that does not exist. ---

    local unknown_help_output
    expect_same_help "Show the help of an unknown command" "help no-such-command" 0 "unknown_help_output"
    expect_output_string "$unknown_help_output" "^Unknown command: no-such-command$" "The unknown command is named"
    expect_output_string "$unknown_help_output" "^Usage: psi \[options\] \[command\]$" "The help of the whole CLI follows"

    # --- 4. Running a command that does not exist. ---

    local unknown_command_output
    expect_same_help "Run an unknown command (should fail)" "no-such-command" 1 "unknown_command_output"
    expect_output_string "$unknown_command_output" "unknown command 'no-such-command'" "The unknown command is reported"

    test_passed
}

test_help "${1:-94}"
