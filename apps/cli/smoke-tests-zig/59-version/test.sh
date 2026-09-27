#!/bin/bash
DESCRIPTION="Zig version: Display version information"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../smoke-tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/interop.sh"
trap cleanup_and_show_summary EXIT

print_test_header 59 "VERSION"

# The version command of the Zig CLI (quiet, so the news shown once per config does not differ between the runs).
zig_version_output=""
invoke_command "Show version information (Zig)" "NO_COLOR=1 $(get_zig_cli_command) -q version" 0 "zig_version_output"
expect_output_string "$zig_version_output" "Version Information" "Version output has the title"
expect_output_string "$zig_version_output" "Database version: 6" "Version output has the database version"
expect_output_string "$zig_version_output" "Dependencies:" "Version output lists the dependencies"
expect_output_string "$zig_version_output" "Directories:" "Version output lists the directories"

# The --version option of the Zig CLI.
zig_version_option_output=""
invoke_command "Show the version number (Zig)" "$(get_zig_cli_command) --version" 0 "zig_version_option_output"

# The compiled TypeScript CLI prints the same.
ts_version_output=""
invoke_command "Show version information (TypeScript)" "NO_COLOR=1 $(get_ts_cli_command) -q version" 0 "ts_version_output"
ts_version_option_output=""
invoke_command "Show the version number (TypeScript)" "$(get_ts_cli_command) --version" 0 "ts_version_option_output"
if [ "$zig_version_output" != "$ts_version_output" ] || [ "$zig_version_option_output" != "$ts_version_option_output" ]; then
    log_error "The Zig CLI and the TypeScript CLI print different version information"
    exit 1
fi
log_success "The Zig CLI and the TypeScript CLI print the same version information"
test_passed
