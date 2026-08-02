#!/bin/bash
DESCRIPTION="S3 path shapes: simple, deep, colon form and awkward filenames"

# Four databases in one bucket, each created and read back, each asserted not to see the others'
# assets. Sharing a bucket is the point: a prefix that is not applied correctly turns into a database
# that reads back its neighbours' files, or reads back nothing at all.
#
# The colon form (`s3:bucket:/prefix`) is the shape the S3 browser writes into databases.json
# (packages/user-interface/src/components/s3-browser-modal.tsx line 111) and that
# apps/cli/smoke-tests-lan-share.sh line 238 uses, so it occurs in the wild, but no CLI test has ever
# used it. Both forms have to keep working.
#
# The colon-form section currently FAILS and is left failing on purpose, and it is placed last so
# everything before it still runs and reports. Nothing in the storage layer understands the `bucket:`
# segment: CloudStorage.parsePath (packages/storage/src/lib/cloud-storage.ts lines 75-91) and
# parseS3ListPath (packages/storage/src/lib/s3-path.ts lines 23-36) both split the path at the first
# "/" and take everything before it as the bucket name, so `bucket:/prefix` asks the server for a
# bucket literally named "bucket:" and the request comes back InvalidBucketName. A database chosen
# through the app's own S3 browser is therefore written into databases.json in a form this code cannot
# open.
#
# The fourth database imports files whose names carry a space and a non-ASCII character, because those
# become object keys and an unescaped key is a request that names the wrong object.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-72}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

#
# Creates a database at the given S3 path, imports one named file into it, and asserts the import is
# listed back. Usage: create_and_read_back <s3-path> <source-file> <expected-name>
#
create_and_read_back() {
    local s3_path="$1"
    local source_file="$2"
    local expected_name="$3"

    invoke_command "Initialize the database at $s3_path" \
        "$(get_cli_command) init --db \"$s3_path\" --yes" 0

    invoke_command "Add $expected_name to $s3_path" \
        "$(get_cli_command) add \"$source_file\" --db \"$s3_path\" --yes" 0

    local list_output
    invoke_command "List $s3_path" "$(get_cli_command) list --db \"$s3_path\" --yes" 0 "list_output"
    expect_output_string "$list_output" "$expected_name" "$s3_path lists its own import"
}

#
# Asserts a database does NOT list a file that belongs to one of the other databases in the bucket.
# Usage: expect_not_listed <s3-path> <foreign-name>
#
expect_not_listed() {
    local s3_path="$1"
    local foreign_name="$2"

    local list_output
    invoke_command "List $s3_path to check for foreign assets" "$(get_cli_command) list --db \"$s3_path\" --yes" 0 "list_output"
    expect_output_string "$list_output" "$foreign_name" "$s3_path does not see $foreign_name" "false"
}

test_s3_paths() {
    local test_number="$1"
    print_test_header "$test_number" "S3 PATH SHAPES"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    # Fixtures with awkward names, built by copying the standard ones under new names. A space and a
    # non-ASCII character both have to survive the round trip into an object key and back.
    local awkward_dir="$TEST_DIR/awkward"
    mkdir -p "$awkward_dir"
    local awkward_space_file="$awkward_dir/a photo with spaces.jpg"
    local awkward_unicode_file="$awkward_dir/phötö-ünïcode.png"
    cp "$TEST_FILES_DIR/test.jpg" "$awkward_space_file"
    cp "$TEST_FILES_DIR/test.png" "$awkward_unicode_file"

    local simple_db="s3:$S3_EMULATOR_BUCKET/simple"
    local deep_db="s3:$S3_EMULATOR_BUCKET/a/b/c/deep"
    local colon_db="s3:$S3_EMULATOR_BUCKET:/colon-form"
    local awkward_db="s3:$S3_EMULATOR_BUCKET/awkward-names"

    # --- Each path shape creates a database and reads its own import back. ---

    create_and_read_back "$simple_db" "$TEST_FILES_DIR/test.jpg" "test.jpg"
    create_and_read_back "$deep_db" "$TEST_FILES_DIR/test.png" "test.png"

    invoke_command "Initialize the awkward-names database" \
        "$(get_cli_command) init --db \"$awkward_db\" --yes" 0
    invoke_command "Add a file whose name contains a space" \
        "$(get_cli_command) add \"$awkward_space_file\" --db \"$awkward_db\" --yes" 0
    invoke_command "Add a file whose name contains non-ASCII characters" \
        "$(get_cli_command) add \"$awkward_unicode_file\" --db \"$awkward_db\" --yes" 0

    local awkward_list
    invoke_command "List the awkward-names database" "$(get_cli_command) list --db \"$awkward_db\" --yes" 0 "awkward_list"
    expect_output_string "$awkward_list" "a photo with spaces.jpg" "The name containing a space survives the round trip"
    expect_output_string "$awkward_list" "phötö-ünïcode.png" "The name containing non-ASCII characters survives the round trip"

    # --- No database sees any other's assets. ---

    expect_not_listed "$simple_db" "test.png"
    expect_not_listed "$simple_db" "a photo with spaces.jpg"
    expect_not_listed "$deep_db" "test.jpg"
    expect_not_listed "$deep_db" "a photo with spaces.jpg"
    expect_not_listed "$awkward_db" "test.jpg"
    expect_not_listed "$awkward_db" "test.png"

    # --- The colon form the S3 browser produces. Last, because it fails; see the header. ---

    create_and_read_back "$colon_db" "$TEST_FILES_DIR/test.webp" "test.webp"
    expect_not_listed "$colon_db" "test.jpg"
    expect_not_listed "$simple_db" "test.webp"

    test_passed
}

test_s3_paths "$TEST_NUMBER"
