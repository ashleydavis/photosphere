#!/bin/bash
DESCRIPTION="An unreachable or wrong S3 target fails loudly"

# Three ways for S3 to be unavailable, each of which must produce a non-zero exit and an error, never
# an empty-but-successful result. An empty database and an unreachable database look identical to a
# user, so a silent success here is how a backup ends up believed-good and empty.
#
# The third assertion is the one that matters most, and it currently FAILS. The emulator is stopped
# while an import of a directory is in flight, so the write path loses its server mid-operation.
# `psi add` then exits 0. Its output does say "Files failed: 5" and prints a warning, so the failure
# is not invisible to a person reading the terminal, but the exit code a script or a scheduled backup
# checks says the import succeeded when not one file was written. That is left failing and reported
# rather than worked around.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-74}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"
MID_IMPORT_STATE_DIR="$TEST_DIR/s3-mid-import"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    stop_s3_emulator "$MID_IMPORT_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

test_s3_failures() {
    local test_number="$1"
    print_test_header "$test_number" "S3 FAILURES"

    mkdir -p "$TEST_DIR"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    local s3_db="s3:$S3_EMULATOR_BUCKET/failure-test"
    log_info "Database path: $s3_db"

    invoke_command "Initialize the S3 database" "$(get_cli_command) init --db \"$s3_db\" --yes" 0
    invoke_command "Add an image to the S3 database" \
        "$(get_cli_command) add $TEST_FILES_DIR/test.jpg --db \"$s3_db\" --yes" 0

    # Prove the database really does read back while the server is up, so the failures below are the
    # server going away and not a database that never worked.
    local working_list
    invoke_command "List the S3 database while the server is up" "$(get_cli_command) list --db \"$s3_db\" --yes" 0 "working_list"
    expect_output_string "$working_list" "test.jpg" "The database reads back while the server is up"

    # --- 2. Wrong bucket, on a live server. ---

    # Done before the emulator is stopped, because it needs a server that answers.
    local wrong_bucket_output
    invoke_command "Summarise a database in a bucket that does not exist" \
        "$(get_cli_command) summary --db \"s3:no-such-bucket/db\" --yes" 1 "wrong_bucket_output"
    expect_output_string "$wrong_bucket_output" "Total files:" "A missing bucket reports no summary" "false"

    # --- 1. Dead endpoint. ---

    log_info "Stopping the S3 emulator; every command below must now fail"
    stop_s3_emulator "$S3_STATE_DIR"

    local dead_list_output
    invoke_command "List with the endpoint dead" "$(get_cli_command) list --db \"$s3_db\" --yes" 1 "dead_list_output"
    expect_output_string "$dead_list_output" "test.jpg" "A dead endpoint lists no assets" "false"

    local dead_summary_output
    invoke_command "Summarise with the endpoint dead" "$(get_cli_command) summary --db \"$s3_db\" --yes" 1 "dead_summary_output"
    expect_output_string "$dead_summary_output" "Total files:" "A dead endpoint reports no summary" "false"

    # --- 3. The endpoint dies while an import is running. ---

    # A second emulator on its own state directory, so this section starts from a healthy server
    # regardless of what the sections above did to the first one.
    start_s3_emulator "$MID_IMPORT_STATE_DIR"
    export_s3_env_credentials

    local mid_import_db="s3:$S3_EMULATOR_BUCKET/mid-import"
    invoke_command "Initialize a database for the mid-import test" \
        "$(get_cli_command) init --db \"$mid_import_db\" --yes" 0

    local import_log="$TEST_DIR/mid-import.log"
    log_info "Starting an import and stopping the server underneath it"

    # The import runs in the background; the emulator is stopped a moment later, while the import is
    # still working through the directory. A short wait is all it takes: the import has to transcode
    # and upload several files, which takes far longer than this.
    NODE_ENV=testing $(get_cli_command) add "$MULTIPLE_IMAGES_DIR/" --db "$mid_import_db" --yes > "$import_log" 2>&1 &
    local import_pid=$!
    sleep 2
    stop_s3_emulator "$MID_IMPORT_STATE_DIR"

    wait "$import_pid"
    local import_exit_code=$?
    log_info "The import exited with code $import_exit_code"
    echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    cat "$import_log"
    echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

    if [ "$import_exit_code" -eq 0 ]; then
        log_error "The import exited 0 after the S3 endpoint was stopped underneath it"
        log_error "Its output above reports how many files failed, but the exit code says the import succeeded"
        log_error "An import that exits zero having written nothing is how a scripted backup ends up silently incomplete"
        exit 1
    fi
    log_success "The import failed when it lost the S3 endpoint, rather than reporting a partial success"

    test_passed
}

test_s3_failures "$TEST_NUMBER"
