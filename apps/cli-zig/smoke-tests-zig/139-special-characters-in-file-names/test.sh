#!/bin/bash
DESCRIPTION="A photo, a picture and a video whose names hold a space, \$, a backtick and a double quote are added with their thumbnails"

# A JPEG, a PNG and an MP4 are copied into a photos directory under names holding a space, `$` and a
# backtick, and a `"` too except on Windows, where `"` is reserved in file names. The directory is added
# and every file must be added with a JPEG thumbnail. Only the directory goes through invoke_command,
# which runs its command with eval and would reparse those names: the CLI finds the files by listing it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

test_special_characters_in_file_names() {
    local test_number="$1"
    print_test_header "$test_number" "SPECIAL CHARACTERS IN FILE NAMES"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local photos_dir="$test_dir/photos"
    local db_dir="$test_dir/db"
    mkdir -p "$photos_dir"

    # Single quotes, so the shell expands nothing in the names.
    local jpg_name='Trip $5 `a`.jpg'
    local png_name='Card $6 `b`.png'
    local mp4_name='Clip $7 `c`.mp4'
    if [ "$(detect_platform)" != "win" ]; then
        jpg_name='Trip $5 `a` "x".jpg'
        png_name='Card $6 `b` "y".png'
        mp4_name='Clip $7 `c` "z".mp4'
    fi
    cp "$TEST_FILES_DIR/test.jpg" "$photos_dir/$jpg_name"
    cp "$TEST_FILES_DIR/test.png" "$photos_dir/$png_name"
    cp "$MULTIPLE_IMAGES_DIR/test.mp4" "$photos_dir/$mp4_name"
    check_exists "$photos_dir/$jpg_name" "The JPEG with special characters in its name"
    check_exists "$photos_dir/$png_name" "The PNG with special characters in its name"
    check_exists "$photos_dir/$mp4_name" "The MP4 with special characters in its name"

    invoke_command "Initialize a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes" 0

    local add_output
    invoke_command "Add the photos directory" "$(get_zig_cli_command) add --db \"$db_dir\" \"$photos_dir\" --verbose --yes" 0 "add_output"
    expect_output_value "$add_output" "Files added:" "3" "All three files are added"
    expect_output_value "$add_output" "Files failed:" "0" "No file fails"

    # The match starts at fixed text none of the names holds, so a quote in a path cannot be taken for an id.
    local asset_ids
    asset_ids="$(echo "$add_output" | grep -o 'to the database with ID "[^"]*"' | sed -n 's/.*with ID "\([^"]*\)".*/\1/p')"
    local id_count
    id_count="$(echo "$asset_ids" | grep -c .)"
    if [ "$id_count" -ne 3 ]; then
        log_error "Expected 3 asset ids in the add output, found $id_count"
        exit 1
    fi
    local asset_id
    for asset_id in $asset_ids; do
        check_exists "$db_dir/thumb/$asset_id" "The thumbnail of $asset_id"
        expect_image "$db_dir/thumb/$asset_id" "image/jpeg" "The thumbnail of $asset_id"
    done

    local summary_output
    invoke_command "Summarize the database" "$(get_zig_cli_command) summary --db \"$db_dir\" --yes" 0 "summary_output"
    expect_output_value "$summary_output" "Files imported:" "3" "The summary counts the three files"

    verify_database "$db_dir"
    test_passed
}

test_special_characters_in_file_names 139
