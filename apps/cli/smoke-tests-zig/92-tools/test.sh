#!/bin/bash
DESCRIPTION="psi tools reports the media tools it finds on the PATH, and fails listing install steps when they are missing"

# The suite's setup runs `tools --yes` for its exit code alone. This test checks what the command
# reports, both with the tools on the PATH and with a PATH that holds none of them, and that the
# TypeScript CLI reports the same in both cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_tools() {
    local test_number="$1"
    print_test_header "$test_number" "TOOLS"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"

    # --- 1. The tools the suite installed are found. ---

    local tools_output
    invoke_command "Check the tools with the Zig CLI" "$(get_zig_cli_command) -q tools --yes" 0 "tools_output"

    expect_output_string "$tools_output" "Media Processing Tools Status" "The report has its heading"
    # The CLIs name ImageMagick by the commands they use: `magick` when ImageMagick 7 puts it on the
    # PATH (as Homebrew and Chocolatey do), otherwise the `convert` and `identify` of ImageMagick 6.
    local imagemagick_name="ImageMagick (convert/identify)"
    if command -v magick > /dev/null 2>&1; then
        imagemagick_name="ImageMagick (magick)"
    fi
    expect_output_string "$tools_output" "$imagemagick_name: Available" "ImageMagick is found"
    expect_output_string "$tools_output" "ffmpeg: Available" "ffmpeg is found"
    expect_output_string "$tools_output" "ffprobe: Available" "ffprobe is found"
    expect_output_string "$tools_output" "All tools are available and ready to use!" "The report says every tool is available"

    local ts_tools_output
    invoke_command "Check the tools with the TypeScript CLI" "$(get_cli_command) -q tools --yes" 0 "ts_tools_output"
    expect_value "$tools_output" "$ts_tools_output" "The Zig CLI reports what the TypeScript CLI reports"

    # --- 2. A PATH without the tools. ---

    # An empty directory as the whole PATH: the CLIs themselves are run by path, so nothing but the
    # tools is lost.
    local empty_path_dir="$test_dir/empty-path"
    mkdir -p "$empty_path_dir"

    local missing_output
    invoke_command "Check the tools with the Zig CLI and no tools on the PATH (should fail)" "PATH=\"$empty_path_dir\" $(get_zig_cli_command) -q tools --yes" 1 "missing_output"

    expect_output_string "$missing_output" "ImageMagick: Not found" "ImageMagick is reported missing"
    expect_output_string "$missing_output" "ffmpeg: Not found" "ffmpeg is reported missing"
    expect_output_string "$missing_output" "ffprobe: Not found" "ffprobe is reported missing"
    expect_output_string "$missing_output" "3 tool(s) missing: ImageMagick, ffmpeg, ffprobe" "The report counts the missing tools"
    expect_output_string "$missing_output" "Installation Instructions:" "The report says how to install them"

    # Run from the sources, the TypeScript CLI is started through `bun run`, which finds bun and a
    # shell on the PATH. With an empty PATH it is started by bun's full path instead.
    local ts_cli_command
    ts_cli_command="$(get_cli_command)"
    if [ "$USE_BINARY" != "true" ]; then
        ts_cli_command="\"$(command -v bun)\" index.ts"
    fi

    local ts_missing_output
    invoke_command "Check the tools with the TypeScript CLI and no tools on the PATH (should fail)" "PATH=\"$empty_path_dir\" $ts_cli_command -q tools --yes" 1 "ts_missing_output"
    expect_value "$missing_output" "$ts_missing_output" "The Zig CLI reports missing tools as the TypeScript CLI does"

    test_passed
}

test_tools "${1:-92}"
