#!/bin/bash
DESCRIPTION="Concurrent writers against one S3 database"

# CloudStorage.acquireWriteLock / refreshWriteLock / releaseWriteLock
# (packages/storage/src/lib/cloud-storage.ts lines 547-730) implement mutual exclusion on a store with
# no native locking primitive. Nothing exercises them under contention from real processes: the only
# path that did was apps/cli/write-lock-smoke-test.sh --cloud, which names a real AWS bucket and so
# has never run here.
#
# Four CLI processes each import a distinct file into the same S3 database at the same time. The
# assertions are that every process exited zero, that the database still verifies, and that the asset
# count equals the number of imports. A lost update, which is what a broken lock produces, shows up as
# a count that is short: each writer read the database, added its own asset, and wrote back over
# somebody else's addition.
#
# Each process writes its own output file under the test's scratch directory, so a failure can be read
# back afterwards rather than being interleaved on one stream.
#
# apps/cli/write-lock-smoke-test.sh is deliberately not reused and not modified: its --cloud mode
# targets a real AWS bucket.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-76}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"

# One writer per fixture. Four concurrent processes is what apps/cli/write-lock-smoke-test.sh uses.
WRITER_FILES=(
    "test.jpg"
    "test.png"
    "test.webp"
    "multiple-files/test-1.jpeg"
)

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

test_s3_write_locks() {
    local test_number="$1"
    print_test_header "$test_number" "S3 WRITE LOCKS UNDER CONTENTION"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    local output_dir="$TEST_DIR/writer-output"
    mkdir -p "$output_dir"

    local s3_db="s3:$S3_EMULATOR_BUCKET/write-locks"
    log_info "Database path: $s3_db"

    invoke_command "Initialize the S3 database" "$(get_cli_command) init --db \"$s3_db\" --yes" 0

    # --- Start every writer at once. ---

    local writer_pids=()
    local writer_index=0
    local writer_file
    for writer_file in "${WRITER_FILES[@]}"; do
        log_info "Starting writer $writer_index for $writer_file"
        NODE_ENV=testing $(get_cli_command) add "$TEST_FILES_DIR/$writer_file" --db "$s3_db" --yes \
            > "$output_dir/writer-$writer_index.log" 2>&1 &
        writer_pids+=($!)
        writer_index=$((writer_index + 1))
    done

    # --- Every writer must have succeeded. ---

    local failed_writers=0
    writer_index=0
    local writer_pid
    for writer_pid in "${writer_pids[@]}"; do
        if wait "$writer_pid"; then
            log_success "Writer $writer_index (${WRITER_FILES[$writer_index]}) exited zero"
        else
            log_error "Writer $writer_index (${WRITER_FILES[$writer_index]}) failed. Its output:"
            cat "$output_dir/writer-$writer_index.log"
            failed_writers=$((failed_writers + 1))
        fi
        writer_index=$((writer_index + 1))
    done

    if [ "$failed_writers" -ne 0 ]; then
        log_error "$failed_writers of ${#WRITER_FILES[@]} concurrent writers failed against the same S3 database"
        exit 1
    fi

    # --- The database is intact and holds every import. ---

    local verify_output
    invoke_command "Verify the S3 database after concurrent writes" \
        "$(get_cli_command) verify --db \"$s3_db\" --yes" 0 "verify_output"
    expect_output_string "$verify_output" "Database verification passed" "The database verifies after concurrent writes"

    # Every writer imported a different file, so all of them have to be listed. A missing one is a lost
    # update: that writer's addition was overwritten by another writer's write-back.
    local list_output
    invoke_command "List the S3 database after concurrent writes" \
        "$(get_cli_command) list --db \"$s3_db\" --yes" 0 "list_output"

    for writer_file in "${WRITER_FILES[@]}"; do
        expect_output_string "$list_output" "$(basename "$writer_file")" "$(basename "$writer_file") survived the concurrent writes"
    done

    local summary_output
    invoke_command "Summarise the S3 database after concurrent writes" \
        "$(get_cli_command) summary --db \"$s3_db\" --yes" 0 "summary_output"
    expect_output_value "$summary_output" "Files imported:" "${#WRITER_FILES[@]}" "Every concurrent import is counted"

    test_passed
}

test_s3_write_locks "$TEST_NUMBER"
