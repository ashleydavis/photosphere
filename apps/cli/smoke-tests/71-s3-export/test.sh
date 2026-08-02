#!/bin/bash
DESCRIPTION="Byte-exact export of an image and a video out of S3"

# Exporting is the one operation that reads a whole asset back out of the bucket, and on S3 every read
# goes through S3RangeReadableStream (packages/storage/src/lib/cloud-storage.ts line 379). A byte-exact
# match between the exported file and the source is what proves that stream returned the entire object
# rather than a truncated first chunk: a truncated export still writes a file, still exits zero, and
# still looks like a successful export.
#
# A video is exported as well as an image because the two take different sizes through the same path.
#
# KNOWN GAP: the multipart upload path (`Upload` with a 100 MB partSize in writeStream) and the
# multi-chunk read path (the chunk ladder in S3RangeReadableStream starts at 100 MB) only engage on
# objects larger than 100 MB. No fixture here is anywhere near that, so this test covers the
# single-chunk path only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-71}"

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
# Extracts the asset id the CLI reported for a just-added file, from the verbose `add` output.
# Usage: asset_id_from_add_output <output>
#
asset_id_from_add_output() {
    local add_output="$1"
    echo "$add_output" | grep "Added file.*to the database with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1
}

#
# Exports one asset out of the S3 database and fails unless the exported file is byte-identical to the
# file that was imported. Usage: expect_byte_exact_export <s3-db> <asset-id> <source-file> <output-file>
#
expect_byte_exact_export() {
    local s3_db="$1"
    local asset_id="$2"
    local source_file="$3"
    local output_file="$4"

    invoke_command "Export $asset_id out of S3" \
        "$(get_cli_command) export $asset_id \"$output_file\" --db \"$s3_db\" --yes" 0

    if [ ! -f "$output_file" ]; then
        log_error "The export command reported success but wrote no file at $output_file"
        exit 1
    fi

    if cmp -s "$output_file" "$source_file"; then
        log_success "The exported file is byte-identical to $source_file"
        return 0
    fi

    log_error "The exported file differs from the source file"
    log_error "Source:   $source_file ($(wc -c < "$source_file") bytes)"
    log_error "Exported: $output_file ($(wc -c < "$output_file") bytes)"
    exit 1
}

test_s3_export() {
    local test_number="$1"
    print_test_header "$test_number" "S3 EXPORT"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    mkdir -p "$TEST_DIR"

    local s3_db="s3:$S3_EMULATOR_BUCKET/export-test"
    log_info "Database path: $s3_db"

    invoke_command "Initialize the S3 database" "$(get_cli_command) init --db \"$s3_db\" --yes" 0

    local add_jpg_output
    invoke_command "Add a JPG to the S3 database" \
        "$(get_cli_command) add $TEST_FILES_DIR/test.jpg --db \"$s3_db\" --verbose --yes" 0 "add_jpg_output"
    local jpg_asset_id
    jpg_asset_id="$(asset_id_from_add_output "$add_jpg_output")"
    if [ -z "$jpg_asset_id" ]; then
        log_error "Could not read the asset id for test.jpg out of the add output"
        exit 1
    fi

    local add_mp4_output
    invoke_command "Add an MP4 to the S3 database" \
        "$(get_cli_command) add $TEST_FILES_DIR/multiple-files/test.mp4 --db \"$s3_db\" --verbose --yes" 0 "add_mp4_output"
    local mp4_asset_id
    mp4_asset_id="$(asset_id_from_add_output "$add_mp4_output")"
    if [ -z "$mp4_asset_id" ]; then
        log_error "Could not read the asset id for test.mp4 out of the add output"
        exit 1
    fi

    expect_byte_exact_export "$s3_db" "$jpg_asset_id" "$TEST_FILES_DIR/test.jpg" "$TEST_DIR/exported-test.jpg"
    expect_byte_exact_export "$s3_db" "$mp4_asset_id" "$TEST_FILES_DIR/multiple-files/test.mp4" "$TEST_DIR/exported-test.mp4"

    test_passed
}

test_s3_export "$TEST_NUMBER"
