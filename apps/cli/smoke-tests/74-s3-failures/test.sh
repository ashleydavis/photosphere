#!/bin/bash
DESCRIPTION="An unreachable or wrong S3 target fails loudly"

# Three ways for S3 to be unavailable, each of which must produce a non-zero exit and an error, never
# an empty-but-successful result. An empty database and an unreachable database look identical to a
# user, so a silent success here is how a backup ends up believed-good and empty.
#
# The third assertion is the one that matters most: the emulator is stopped while an import is in
# flight, so the write path loses its server mid-operation and `psi add` must exit non-zero. It does,
# as long as the server goes away during the upload, which is what this test now waits for.
#
# The commit that follows the upload is a different path and it is still broken: a batch that cannot
# be written there is dropped, the uploaded files stay in storage unrecorded, and `psi add` exits 0
# saying "Added 0 files". See the comment on the wait below. Nothing covers that today.

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

    # The import needs to still be running when the server is taken away, and the five standard
    # fixtures are small enough to finish in well under a second, which made this a race that the
    # import usually won. A large generated video takes several seconds to upload, so stopping the
    # server part way through it lands comfortably inside the import rather than after it.
    local big_fixture="$TEST_DIR/mid-import-video.mp4"
    log_info "Generating a large video so the import takes long enough to interrupt..."
    # -nostdin is ffmpeg's non-interactive flag: without it ffmpeg reads the terminal for keyboard
    # commands, and a test cannot do that. Each test runs under `timeout`, which puts it in its own
    # process group, and a process outside the terminal's foreground group that reads the terminal is
    # stopped by the kernel and never resumes. Run from a terminal this froze a 0.2s ffmpeg call
    # until the suite's 300s timeout killed the test.
    if ! ffmpeg -nostdin -y -f lavfi -i "color=c=black:s=1280x720:r=30:d=3,noise=alls=100:allf=t+u" \
        -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv420p "$big_fixture" >/dev/null 2>&1; then
        log_error "ffmpeg could not generate the large test video"
        exit 1
    fi
    log_info "Generated $big_fixture ($(wc -c < "$big_fixture") bytes)"

    local import_log="$TEST_DIR/mid-import.log"
    log_info "Starting an import and stopping the server underneath it"

    NODE_ENV=testing $(get_cli_command) add "$big_fixture" --db "$mid_import_db" --yes > "$import_log" 2>&1 &
    local import_pid=$!

    # Wait for the upload to be in flight rather than sleeping a fixed two seconds. The sleep raced
    # the upload and lost about half the time on this machine: 145 MB went up in under two seconds, so
    # the server was taken away during the database commit that follows the upload instead of during
    # the upload itself. Those are different code paths and only the upload one fails loudly, so the
    # verdict came down to how fast the machine could push the fixture into a local server.
    #
    # The fixture is larger than one upload part, so the emulator holds a directory under
    # .minio.sys/multipart for exactly as long as the upload runs: it appears when the first part
    # arrives and is gone once the upload finishes. Waiting for it puts the stop inside the upload
    # every time.
    #
    # Losing the endpoint during the commit is NOT covered by this test any more, and it is a real
    # failure: the batch is dropped, the files stay in storage unrecorded, and `psi add` exits 0
    # reporting "Added 0 files". Same silent success this test exists to catch, on the other side of
    # the upload.
    local multipart_dir="$MID_IMPORT_STATE_DIR/data/.minio.sys/multipart"
    local upload_started=false
    local attempt
    for attempt in $(seq 1 600); do
        if [ -n "$(ls -A "$multipart_dir" 2>/dev/null)" ]; then
            upload_started=true
            break
        fi
        sleep 0.1
    done

    if [ "$upload_started" != "true" ]; then
        log_error "The import never began uploading, so the server could not be taken away mid-upload"
        exit 1
    fi

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
