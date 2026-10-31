#!/bin/bash
DESCRIPTION="The Zig CLI needs no installed media tools: a copy of the binary, alone on the PATH, adds a photo and a video and makes the video's thumbnail"

# The Zig binary is copied alone into a directory of this test and run with a PATH that holds only that
# directory, so no installed magick, convert, identify, ffmpeg or ffprobe can be found. The test fails if
# any of them can be. init, add of a photo and of a video, summary, list and verify are run with asserted
# output and exit codes, and the video's thumbnail is checked to exist and to be a JPEG. The script's own
# commands (the image check of the thumbnail) keep the normal PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Prints the asset id from the verbose output of a `psi add` of one new file, or fails the test when
# there is none.
# Usage: added_asset_id <add output> <what was added>
#
added_asset_id() {
    local add_output="$1"
    local file_description="$2"
    local asset_id
    asset_id="$(echo "$add_output" | grep "Added file.*to the database with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$asset_id" ]; then
        log_error "No asset id for the $file_description in the add output" >&2
        exit 1
    fi
    echo "$asset_id"
}

test_built_in_media_tools() {
    local test_number="$1"
    print_test_header "$test_number" "BUILT-IN MEDIA TOOLS"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local bin_dir="$test_dir/bin"
    local db_dir="$test_dir/db"
    mkdir -p "$bin_dir"

    # Copied under its own file name, so it keeps the .exe it has on Windows.
    local zig_binary
    zig_binary="$(get_zig_cli_command)"
    local psi_path="$bin_dir/$(basename "$zig_binary")"
    cp "$zig_binary" "$psi_path"

    # None of the media tools can be reached with the restricted PATH. `command -v` also finds a
    # name with .exe on Windows.
    local tool_name
    for tool_name in magick convert identify ffmpeg ffprobe; do
        local found_path
        found_path="$(PATH="$bin_dir"; hash -r; command -v "$tool_name" || true)"
        if [ -n "$found_path" ]; then
            log_error "$tool_name is found at $found_path with PATH=$bin_dir, so the test cannot show the Zig CLI runs without it"
            exit 1
        fi
    done
    log_success "None of magick, convert, identify, ffmpeg or ffprobe can be found with PATH=$bin_dir"

    local psi="PATH=\"$bin_dir\" \"$psi_path\""

    invoke_command "Initialize a database" "$psi init --db \"$db_dir\" --yes" 0
    check_exists "$db_dir/.db" "The database directory"

    local photo_output
    invoke_command "Add the photo" "$psi add --db \"$db_dir\" \"$TEST_FILES_DIR/test.jpg\" --verbose --yes" 0 "photo_output"
    expect_output_value "$photo_output" "Files added:" "1" "The photo is added"
    expect_output_value "$photo_output" "Files failed:" "0" "Nothing failed adding the photo"
    local photo_id
    photo_id="$(added_asset_id "$photo_output" "photo")" || exit 1
    check_exists "$db_dir/thumb/$photo_id" "The photo's thumbnail"
    expect_image "$db_dir/thumb/$photo_id" "image/jpeg" "The photo's thumbnail"

    local video_output
    invoke_command "Add the video" "$psi add --db \"$db_dir\" \"$MULTIPLE_IMAGES_DIR/test.mp4\" --verbose --yes" 0 "video_output"
    expect_output_value "$video_output" "Files added:" "1" "The video is added"
    expect_output_value "$video_output" "Files failed:" "0" "Nothing failed adding the video"
    local video_id
    video_id="$(added_asset_id "$video_output" "video")" || exit 1
    check_exists "$db_dir/thumb/$video_id" "The video's thumbnail"
    expect_image "$db_dir/thumb/$video_id" "image/jpeg" "The video's thumbnail"

    local summary_output
    invoke_command "Summarize the database" "$psi summary --db \"$db_dir\" --yes" 0 "summary_output"
    expect_output_value "$summary_output" "Files imported:" "2" "The summary counts the photo and the video"

    local list_output
    invoke_command "List the assets" "$psi list --db \"$db_dir\" --page-size 50 --yes" 0 "list_output"
    expect_output_string "$list_output" "$photo_id" "The list holds the photo"
    expect_output_string "$list_output" "$video_id" "The list holds the video"

    invoke_command "Verify the database" "$psi verify --db \"$db_dir\" --yes" 0
}

test_built_in_media_tools 105
