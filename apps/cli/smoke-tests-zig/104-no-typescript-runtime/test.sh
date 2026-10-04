#!/bin/bash
DESCRIPTION="The Zig CLI runs on its own: a copy of the binary, with no bun or node on the PATH, runs the common commands"

# The Zig binary is copied alone into a directory of this test and run with a PATH that holds only the
# directories of magick, ffmpeg and ffprobe, the external tools the TypeScript CLI also needs. The test
# fails if bun or node can be found in any of those directories. init, add, summary, list, export and
# verify are run with asserted output and exit codes, then the TypeScript CLI checks the database with the
# normal PATH. The binary is also checked not to be a bun-compiled executable: a bun-compiled executable
# carries bun's embedded-files trailer, which the TypeScript CLI binary has and the Zig binary must not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Builds a PATH out of the directories of the ImageMagick command (magick, or convert where ImageMagick 6 has no
# magick, as the CLI itself falls back), ffmpeg and ffprobe, each once. Prints nothing and fails when a tool is
# missing, so the caller reports it.
#
tool_directories_path() {
    local result=""
    local tool_name
    for tool_name in magick ffmpeg ffprobe; do
        local tool_path
        tool_path="$(command -v "$tool_name" || true)"
        if [ -z "$tool_path" ] && [ "$tool_name" = "magick" ]; then
            tool_path="$(command -v convert || true)"
        fi
        if [ -z "$tool_path" ]; then
            return 1
        fi
        local tool_directory
        tool_directory="$(dirname "$tool_path")"
        case ":$result:" in
            *":$tool_directory:"*) ;;
            *) result="${result:+$result:}$tool_directory" ;;
        esac
    done
    echo "$result"
}

test_no_typescript_runtime() {
    local test_number="$1"
    print_test_header "$test_number" "NO TYPESCRIPT RUNTIME"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local bin_dir="$test_dir/bin"
    local db_dir="$test_dir/db"
    local export_dir="$test_dir/export"
    mkdir -p "$bin_dir" "$export_dir"

    local zig_binary
    zig_binary="$(get_zig_cli_command)"
    cp "$zig_binary" "$bin_dir/psi"

    # The binary is not a bun-compiled executable.
    if grep -c -a -F -e '---- Bun! ----' "$bin_dir/psi" > /dev/null 2>&1; then
        log_error "The Zig binary carries bun's embedded-files trailer, so it is a bun-compiled executable"
        exit 1
    fi
    log_success "The Zig binary does not carry bun's embedded-files trailer"

    # Neither bun nor node can be reached with the restricted PATH.
    local restricted_path
    if ! restricted_path="$(tool_directories_path)"; then
        log_error "magick (or convert), ffmpeg or ffprobe is not on the PATH, so the Zig CLI cannot be run with only the tool directories"
        exit 1
    fi
    local directory
    local old_ifs="$IFS"
    IFS=':'
    for directory in $restricted_path; do
        if [ -e "$directory/bun" ] || [ -e "$directory/node" ]; then
            IFS="$old_ifs"
            log_error "bun or node is in $directory, so the restricted PATH cannot keep them out of reach"
            exit 1
        fi
    done
    IFS="$old_ifs"
    log_success "bun and node are in none of: $restricted_path"

    local psi="PATH=\"$restricted_path\" $bin_dir/psi"

    invoke_command "Initialize a database" "$psi init --db \"$db_dir\" --yes" 0
    check_exists "$db_dir/.db" "The database directory"

    invoke_command "Add the PNG" "$psi add --db \"$db_dir\" \"$TEST_FILES_DIR/test.png\" --yes" 0

    local summary_output
    invoke_command "Summarize the database" "$psi summary --db \"$db_dir\" --yes" 0 "summary_output"
    expect_output_string "$summary_output" "Files imported:" "The summary counts the imported files"

    local list_output
    invoke_command "List the assets" "$psi list --db \"$db_dir\" --page-size 50 --yes" 0 "list_output"
    local asset_id
    asset_id="$(echo "$list_output" | grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" | head -1)"
    if [ -z "$asset_id" ]; then
        log_error "No asset id in the list output"
        exit 1
    fi

    invoke_command "Export the asset" "$psi export --db \"$db_dir\" $asset_id \"$export_dir/exported.png\" --yes" 0
    check_exists "$export_dir/exported.png" "The exported file"
    if cmp -s "$TEST_FILES_DIR/test.png" "$export_dir/exported.png"; then
        log_success "The exported file is byte-identical to the file that was added"
    else
        log_error "The exported file differs from the file that was added"
        exit 1
    fi

    invoke_command "Verify the database" "$psi verify --db \"$db_dir\" --yes" 0

    ts_verify "$db_dir"
}

test_no_typescript_runtime 104
