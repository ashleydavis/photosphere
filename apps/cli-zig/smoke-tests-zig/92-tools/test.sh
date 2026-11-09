#!/bin/bash
DESCRIPTION="psi tools reports the versions of the ImageMagick, ffmpeg and ffprobe built into it, whether or not they are on the PATH"

# The suite's setup runs `tools --yes` for its exit code alone. This test checks what the command
# reports, both with the suite's tools on the PATH and with a PATH that holds none of them. The Zig CLI
# runs ImageMagick and FFmpeg from the libraries linked into it, so the report is the same in both
# cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Fails the test unless a `psi tools` report names every built-in tool with its version.
# Usage: expect_built_in_tools <tools output> <what the PATH held>
#
expect_built_in_tools() {
    local tools_output="$1"
    local path_description="$2"
    expect_output_string "$tools_output" "Media Processing Tools" "The report has its heading ($path_description)"
    expect_output_string "$tools_output" "ImageMagick (magick): v7." "ImageMagick is reported with its version ($path_description)"
    expect_output_string "$tools_output" "ffmpeg: v" "ffmpeg is reported with its version ($path_description)"
    expect_output_string "$tools_output" "ffprobe: v" "ffprobe is reported with its version ($path_description)"
}

test_tools() {
    local test_number="$1"
    print_test_header "$test_number" "TOOLS"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"

    # --- 1. The PATH the suite runs with. ---

    local tools_output
    invoke_command "Check the tools with the Zig CLI" "$(get_zig_cli_command) -q tools --yes" 0 "tools_output"
    expect_built_in_tools "$tools_output" "the suite's PATH"

    # --- 2. A PATH without the tools. ---

    # An empty directory as the whole PATH: the CLI itself is run by path, so nothing but the
    # installed tools is lost, and the CLI does not use those.
    local empty_path_dir="$test_dir/empty-path"
    mkdir -p "$empty_path_dir"

    local no_tools_output
    invoke_command "Check the tools with the Zig CLI and no tools on the PATH" "PATH=\"$empty_path_dir\" $(get_zig_cli_command) -q tools --yes" 0 "no_tools_output"
    expect_built_in_tools "$no_tools_output" "an empty PATH"

    test_passed
}

test_tools "${1:-92}"
