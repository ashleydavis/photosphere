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
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

TEST_NUMBER="${1:-65}"
S3_STATE_DIR="$(get_test_dir "$TEST_NUMBER")/s3"

# Stop the app's summary printer AND the emulator, so a failed assertion never leaves a MinIO server
# running. The emulator's stop is safe to call when nothing was started, so it goes in
# unconditionally.
cleanup_s3_and_show_summary() {
    local exit_code=$?
    (cd "$REPO_ROOT" && bun run s3-emulator stop "$S3_STATE_DIR") >/dev/null 2>&1 || true
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

test_s3_database() {
    local test_number="$1"
    print_test_header "$test_number" "S3 DATABASE"

    mkdir -p "$(dirname "$S3_STATE_DIR")"

    # Start the S3 server and read back the port it bound, the bucket it seeded and its credentials.
    if ! (cd "$REPO_ROOT" && bun run s3-emulator start "$S3_STATE_DIR"); then
        log_error "Could not start the local S3 emulator"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$S3_STATE_DIR/env"

    # The CLI reads S3 credentials from these when the database entry names no vault secret, so this
    # is the plain "point the CLI at a bucket" path a user takes with a self-hosted server.
    export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
    export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
    export AWS_REGION="us-east-1"
    log_info "S3 emulator at $AWS_ENDPOINT, bucket $S3_EMULATOR_BUCKET"

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
