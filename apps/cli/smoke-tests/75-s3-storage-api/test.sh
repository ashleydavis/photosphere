#!/bin/bash
DESCRIPTION="The CloudStorage API integration suite, against a local MinIO"

# packages/storage/integration-tests/cloud-storage.test.ts covers the whole CloudStorage surface in
# one place: basic file operations, directory operations, streams, the full write-lock lifecycle,
# error handling and path handling. It has never run: it needs AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY and TEST_S3_BUCKET, and packages/storage/jest.config.js excludes
# integration-tests from the normal run, so `bun run test` never touches it.
#
# This test provides the server it was always waiting for. It starts a local MinIO, exports the
# variables the suite requires, and runs it. The suite's result is this test's result: a failure in
# there is a real finding about CloudStorage.
#
# The suite runs under `bun test` (the package's test:integration script) rather than under Jest,
# which is what everything else in this repository uses. That is not a preference. @aws-sdk/lib-storage
# performs a dynamic import inside Upload, which CloudStorage.write and writeStream both go through,
# and Jest's CommonJS VM cannot service one: every write failed with
# ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING_FLAG. Running Jest with --experimental-vm-modules fixes that
# and immediately breaks the checked-in CommonJS serialize-error mock that five other packages depend
# on, because the flag makes Jest honour the package's "type": "module". Bun runs the same file, with
# the same describe/test/expect API, and executes the dynamic import natively.

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
    print_test_header "$test_number" "CLOUDSTORAGE API AGAINST MINIO"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    # The suite reads the bucket from its own variable rather than from a path.
    export TEST_S3_BUCKET="$S3_EMULATOR_BUCKET"
    log_info "Running the CloudStorage integration suite against $S3_ENDPOINT, bucket $TEST_S3_BUCKET"

    # Run through `bash -c` because invoke_command prefixes the command with an environment
    # assignment, and a shell cannot put one of those in front of a subshell.
    invoke_command "Run the CloudStorage integration suite" \
        "bash -c 'cd \"$REPO_ROOT\" && bun run --filter=storage test:integration'" 0

    test_passed
}

test_s3_storage_api "$TEST_NUMBER"
