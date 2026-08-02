#!/bin/bash
DESCRIPTION="Create, populate and read back a database on S3"

# Drives the CLI against a real S3 server: a local MinIO started by this test on an OS-assigned port
# over plain HTTP, so the test needs no credentials, no account and no configuration, and can never
# skip.
#
# It creates a database at an `s3:` path, imports an image into it, and reads it back with `summary`
# and `list`. Every one of those goes through CloudStorage against the server, so a database that
# reports its asset back has genuinely been written to and read from S3.
#
# The endpoint is `http://localhost:<port>`. Without path-style addressing the SDK puts the bucket
# into the hostname (`bucket.localhost`), which does not name the bucket to the server: the database
# then appears empty rather than failing, which is the silent-wrong-answer this covers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-65}"
S3_STATE_DIR="$(get_test_dir "$TEST_NUMBER")/s3"

# Stop the app's summary printer AND the emulator, so a failed assertion never leaves a MinIO server
# running. The emulator's stop is safe to call when nothing was started, so it goes in
# unconditionally.
cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

test_s3_database() {
    local test_number="$1"
    print_test_header "$test_number" "S3 DATABASE"

    start_s3_emulator "$S3_STATE_DIR"

    # The CLI reads S3 credentials from these when the database entry names no vault secret, so this
    # is the plain "point the CLI at a bucket" path a user takes with a self-hosted server.
    export_s3_env_credentials

    local s3_db="s3:$S3_EMULATOR_BUCKET/cli-smoke-test"
    log_info "Database path: $s3_db"

    invoke_command "Initialize a database on S3" "$(get_cli_command) init --db $s3_db --yes" 0

    invoke_command "Add an image to the S3 database" "$(get_cli_command) add $TEST_FILES_DIR/test.jpg --db $s3_db --yes" 0

    # Read the database back off S3. A summary that reports the imported file proves the write landed
    # in the bucket and was read back out of it, not out of any local cache.
    local summary_output
    invoke_command "Summarise the S3 database" "$(get_cli_command) summary --db $s3_db --yes" 0 "summary_output"
    expect_output_string "$summary_output" "Files imported:" "Summary contains files imported count"
    expect_output_string "$summary_output" "Total files:" "Summary contains total files count"

    # The imported asset must appear by name, which is the assertion that fails if the database read
    # back empty (the failure mode a wrong-addressing S3 client produces).
    local list_output
    invoke_command "List the S3 database's assets" "$(get_cli_command) list --db $s3_db --yes" 0 "list_output"
    expect_output_string "$list_output" "test.jpg" "The imported asset is listed from S3"

    test_passed
}

test_s3_database "$TEST_NUMBER"
