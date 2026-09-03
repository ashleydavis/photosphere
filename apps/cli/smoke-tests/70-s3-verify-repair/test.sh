#!/bin/bash
DESCRIPTION="Verify, repair and orphan handling on an S3 database"

# The S3 counterpart of local tests 15 (deleted file), 16 (modified file), 24 (repair ok) and 26
# (repair damaged). Those all damage a filesystem database with `rm` and `echo >>`; the equivalent
# here is done through the S3 API with scripts/s3-object.ts, which is the only way to reach into a
# bucket from a shell test.
#
# `verify` exits zero whether or not it finds damage, both here and in the local tests: the finding is
# in the counts it prints, and those are what is asserted. Tests 15 and 16 assert the same way.
#
# The repair source is a local replica taken while the database was intact, so the repair genuinely
# has to pull bytes back up into the bucket.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-70}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"
DB_PREFIX="verify-repair"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

#
# Runs a scripts/s3-object.ts subcommand against the emulator's bucket, passing the connection
# settings the emulator reported. Usage: s3_object <subcommand> [args...]
#
s3_object() {
    local subcommand="$1"
    shift
    bun "$REPO_ROOT/scripts/s3-object.ts" "$subcommand" \
        --endpoint "$S3_ENDPOINT" \
        --bucket "$S3_EMULATOR_BUCKET" \
        --access-key "$S3_EMULATOR_ACCESS_KEY" \
        --secret-key "$S3_EMULATOR_SECRET_KEY" \
        "$@"
}

test_s3_verify_repair() {
    local test_number="$1"
    print_test_header "$test_number" "S3 VERIFY AND REPAIR"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    mkdir -p "$TEST_DIR"

    local s3_db="s3:$S3_EMULATOR_BUCKET/$DB_PREFIX"
    local good_replica="$TEST_DIR/good-replica"
    log_info "Database path: $s3_db"

    # Builds rather than copies, and create_db_with_5_files knows that: the database lives in a
    # bucket, and a directory cannot be copied into one.
    create_db_with_5_files "\"$s3_db\""

    # --- 1. An intact database verifies. ---

    local verify_output
    invoke_command "Verify the intact S3 database" "$(get_cli_command) verify --db \"$s3_db\" --yes" 0 "verify_output"
    expect_output_string "$verify_output" "Database verification passed" "The intact S3 database verifies"

    local verify_full_output
    invoke_command "Fully verify the intact S3 database" "$(get_cli_command) verify --db \"$s3_db\" --full --yes" 0 "verify_full_output"
    expect_output_string "$verify_full_output" "Database verification passed" "The intact S3 database fully verifies"

    # Take the repair source now, while the database is intact.
    invoke_command "Replicate the intact database down to a local repair source" \
        "$(get_cli_command) replicate --db \"$s3_db\" --dest $good_replica --yes" 0

    # --- 2. A deleted asset object is reported by verify. ---

    local victim_key
    victim_key="$(s3_object list --prefix "$DB_PREFIX/asset" | sort | head -1)"
    if [ -z "$victim_key" ]; then
        log_error "No asset object found in the bucket to delete"
        exit 1
    fi
    log_info "Deleting asset object from the bucket: $victim_key"
    s3_object delete --key "$victim_key"

    # Exit 1: an object the database expects is gone from the bucket. The verify after the repair
    # below still expects 0, and that pair is what makes the exit code worth anything.
    local verify_deleted_output
    invoke_command "Verify after deleting an asset object" "$(get_cli_command) verify --db \"$s3_db\" --yes" 1 "verify_deleted_output"
    expect_output_value "$verify_deleted_output" "Removed:" "1" "Verify reports the deleted asset object as removed"
    expect_output_value "$verify_deleted_output" "Modified:" "0" "Verify reports no modified files after the deletion"

    # --- 3. Repair from the local replica restores it. ---

    invoke_command "Repair the S3 database from the local replica" \
        "$(get_cli_command) repair --db \"$s3_db\" --source $good_replica --yes" 0

    local verify_repaired_output
    invoke_command "Verify after the repair" "$(get_cli_command) verify --db \"$s3_db\" --yes" 0 "verify_repaired_output"
    expect_output_string "$verify_repaired_output" "Database verification passed" "The repaired S3 database verifies"

    # --- 4. An overwritten asset object is reported by a full verify. ---

    log_info "Overwriting asset object in the bucket with different bytes: $victim_key"
    s3_object put --key "$victim_key" --body "these are not the bytes the database recorded"

    # Exit 1: the object in the bucket no longer hashes to what the database recorded.
    local verify_modified_output
    invoke_command "Fully verify after overwriting an asset object" "$(get_cli_command) verify --db \"$s3_db\" --full --yes" 1 "verify_modified_output"
    expect_output_value "$verify_modified_output" "Modified:" "1" "A full verify reports the overwritten asset object as modified"

    invoke_command "Repair the overwritten object from the local replica" \
        "$(get_cli_command) repair --db \"$s3_db\" --source $good_replica --full --yes" 0

    local verify_repaired_again_output
    invoke_command "Fully verify after the second repair" "$(get_cli_command) verify --db \"$s3_db\" --full --yes" 0 "verify_repaired_again_output"
    expect_output_string "$verify_repaired_again_output" "Database verification passed" "The S3 database verifies again after the overwrite was repaired"

    # --- 5. An unreferenced object in the bucket is reported as an orphan. ---

    local orphan_key="$DB_PREFIX/asset/00000000-0000-0000-0000-00000000beef"
    log_info "Writing an unreferenced object into the bucket: $orphan_key"
    s3_object put --key "$orphan_key" --body "this object is in no merkle tree"

    local orphans_output
    invoke_command "Find orphans in the S3 database" "$(get_cli_command) find-orphans --db \"$s3_db\" --yes" 0 "orphans_output"
    expect_output_string "$orphans_output" "00000000-0000-0000-0000-00000000beef" "The unreferenced object is reported as an orphan"

    test_passed
}

test_s3_verify_repair "$TEST_NUMBER"
