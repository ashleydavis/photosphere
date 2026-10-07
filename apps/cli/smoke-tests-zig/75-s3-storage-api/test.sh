#!/bin/bash
DESCRIPTION="The Zig CloudStorage integration suite, against a local MinIO"

# The Zig counterpart of smoke-tests/75-s3-storage-api, which runs the TypeScript CloudStorage
# integration suite against a local S3 server. Here the suite is its port,
# packages-zig/storage-zig/integration-tests/cloud-storage.test.zig: the same tests of basic file
# operations, directory operations, streams, the full write-lock lifecycle, error handling and path
# handling, run against the CloudStorage the Zig CLI uses for every s3: database. The unit tests never
# run it: it needs AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and TEST_S3_BUCKET, which this test
# provides with the server it starts.
#
# The suite is built through the root build.zig's test-integration step rather than on its own,
# so it reuses what the Zig unit tests compiled (the AWS SDK for C above all)
# instead of compiling it again. The suite's result is this test's result: a failure in there is a
# real finding about the Zig CloudStorage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-75}"

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

test_s3_storage_api() {
    local test_number="$1"
    print_test_header "$test_number" "ZIG CLOUDSTORAGE API AGAINST MINIO"

    if ! command -v zig > /dev/null 2>&1; then
        log_error "zig is not on the PATH, so the Zig CloudStorage integration suite cannot be built (mise install puts it there)"
        exit 1
    fi

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    # The suite reads the bucket from its own variable rather than from a path.
    export TEST_S3_BUCKET="$S3_EMULATOR_BUCKET"
    log_info "Running the Zig CloudStorage integration suite against $S3_ENDPOINT, bucket $TEST_S3_BUCKET"

    # Run through `bash -c` because invoke_command prefixes the command with an environment
    # assignment, and a shell cannot put one of those in front of a subshell.
    invoke_command "Run the Zig CloudStorage integration suite" \
        "bash -c 'cd \"$REPO_ROOT\" && zig build test-integration --summary all --test-timeout 20m'" 0

    test_passed
}

test_s3_storage_api "$TEST_NUMBER"
