#!/bin/bash
DESCRIPTION="Import and export a video larger than one S3 upload part"

# Covers the two S3 code paths that only engage on objects larger than 100 MB, which nothing else
# reaches because every checked-in fixture is a few megabytes:
#
#   - writeStream uploads through `Upload` with a 100 MB partSize
#     (packages/storage/src/lib/cloud-storage.ts line 405), so a larger object is sent as several
#     parts and completed as a multipart upload rather than one PUT.
#   - readStream always goes through S3RangeReadableStream, whose chunk ladder starts at 100 MB
#     (packages/storage/src/lib/s3-range-readable-stream.ts line 10), so reading it back takes
#     several ranged GETs that have to be stitched together in order.
#
# Videos above 100 MB are ordinary for real users, so these paths carry real data.
#
# The fixture is generated here rather than checked in, because a 100 MB+ binary does not belong in
# the repository. It is video noise: a test pattern compresses down to a few megabytes however high
# the bitrate is asked to be, and would quietly stop covering anything. The size is asserted before
# the import for exactly that reason.
#
# A byte-exact export is the assertion. A multi-chunk read that dropped or reordered a chunk still
# produces a stream that ends cleanly and still writes a file, so only comparing the bytes catches it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-77}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"

# The generated fixture has to clear the 100 MB part size with room to spare, so the upload is at
# least two parts and the read at least two chunks. Three seconds of 720p30 noise at lossless quality
# comes out around 145 MB and takes under a second to produce.
MINIMUM_FIXTURE_BYTES=$((100 * 1024 * 1024))
FIXTURE_SECONDS=3

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

test_s3_large_file() {
    local test_number="$1"
    print_test_header "$test_number" "S3 LARGE FILE"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    mkdir -p "$TEST_DIR"

    # --- 1. Generate a video comfortably larger than one upload part. ---

    local fixture="$TEST_DIR/large-video.mp4"
    log_info "Generating a ${FIXTURE_SECONDS}s noise video (this is the >100 MB fixture)..."
    if ! ffmpeg -y -f lavfi -i "color=c=black:s=1280x720:r=30:d=$FIXTURE_SECONDS,noise=alls=100:allf=t+u" \
        -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv420p "$fixture" >/dev/null 2>&1; then
        log_error "ffmpeg could not generate the large test video"
        exit 1
    fi

    local fixture_bytes
    fixture_bytes=$(wc -c < "$fixture")
    log_info "Generated $fixture ($fixture_bytes bytes)"

    # Without this the test could pass while covering nothing at all: a fixture that came out under
    # 100 MB takes the ordinary single-part upload and single-chunk read, which other tests already
    # cover.
    if [ "$fixture_bytes" -le "$MINIMUM_FIXTURE_BYTES" ]; then
        log_error "The generated fixture is $fixture_bytes bytes, which does not exceed the $MINIMUM_FIXTURE_BYTES byte upload part size"
        log_error "It would take the single-part upload and single-chunk read paths, so this test would cover nothing"
        exit 1
    fi
    log_success "The fixture exceeds the 100 MB upload part size, so the multipart and multi-chunk paths will run"

    # --- 2. Import it into an S3 database. ---

    local s3_db="s3:$S3_EMULATOR_BUCKET/large-file"
    log_info "Database path: $s3_db"

    invoke_command "Initialize the S3 database" "$(get_cli_command) init --db \"$s3_db\" --yes" 0

    local add_output
    invoke_command "Add the large video to the S3 database" \
        "$(get_cli_command) add \"$fixture\" --db \"$s3_db\" --verbose --yes" 0 "add_output"

    local asset_id
    asset_id="$(asset_id_from_add_output "$add_output")"
    if [ -z "$asset_id" ]; then
        log_error "Could not read the asset id for the large video out of the add output"
        exit 1
    fi
    log_info "Large video asset id: $asset_id"

    # The asset must exist in the bucket as one object. A multipart upload that never completed leaves
    # its parts unassembled and no object at all.
    local asset_count
    asset_count="$(bun "$REPO_ROOT/scripts/s3-object.ts" count \
        --endpoint "$S3_ENDPOINT" \
        --bucket "$S3_EMULATOR_BUCKET" \
        --access-key "$S3_EMULATOR_ACCESS_KEY" \
        --secret-key "$S3_EMULATOR_SECRET_KEY" \
        --prefix "large-file/asset/$asset_id")"
    expect_value "$asset_count" "1" "The large video is stored in the bucket as one completed object"


    # --- 3. Read it back and compare every byte. ---

    local exported="$TEST_DIR/exported-video.mp4"
    invoke_command "Export the large video back out of S3" \
        "$(get_cli_command) export $asset_id \"$exported\" --db \"$s3_db\" --yes" 0

    if [ ! -f "$exported" ]; then
        log_error "The export command reported success but wrote no file at $exported"
        exit 1
    fi

    local exported_bytes
    exported_bytes=$(wc -c < "$exported")
    expect_value "$exported_bytes" "$fixture_bytes" "The exported video is the same size as the imported one"

    if ! cmp -s "$fixture" "$exported"; then
        log_error "The exported video differs from the imported one"
        log_error "A multi-chunk range read dropped, duplicated or reordered part of the object"
        exit 1
    fi
    log_success "The exported video is byte-identical to the imported one across every chunk"

    test_passed
}

test_s3_large_file "$TEST_NUMBER"
