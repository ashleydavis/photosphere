#!/bin/bash
DESCRIPTION="S3 listings page past the first 1000 keys"

# A single ListObjectsV2 returns at most 1000 keys and sets a continuation token for the rest.
# CloudStorage.listFiles and listDirs (packages/storage/src/lib/cloud-storage.ts lines 114-224) follow
# that token; nothing has ever tested that they do, and the failure mode is silent: a listing that
# stops at the first page reports 1000 of 1100 objects and looks like a complete answer.
#
# 1,100 objects are seeded under one prefix, then counted two ways:
#
#   1. Through scripts/s3-object.ts, which pages the same way. This proves the fixture really contains
#      1,100 objects, so a later count of 1,000 is a paging fault and not a seeding fault.
#   2. Through the app, with `find-orphans` over a database whose bucket prefix holds those objects.
#      None of them is in the merkle tree, so all 1,100 are orphans, and the count the app reports is
#      the count its own listing enumerated.
#
# Building a database of more than 1000 assets is not attempted: importing that many media files takes
# far longer than the suite's per-test budget allows. Seeding plain objects reaches the same listing
# code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-73}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"
DB_PREFIX="pagination"

# Comfortably past one page of 1000 keys. Seeding this many against local MinIO takes about four
# seconds, measured while writing this test, so there is no reason to use a smaller number.
SEED_COUNT=1100

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

test_s3_pagination() {
    local test_number="$1"
    print_test_header "$test_number" "S3 LISTING PAGINATION"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    local s3_db="s3:$S3_EMULATOR_BUCKET/$DB_PREFIX"
    log_info "Database path: $s3_db"

    invoke_command "Initialize the S3 database" "$(get_cli_command) init --db \"$s3_db\" --yes" 0

    # --- 1. The fixture really holds more than one page of objects. ---

    log_info "Seeding $SEED_COUNT objects under $DB_PREFIX/asset ..."
    s3_object seed-many --prefix "$DB_PREFIX/asset" --count "$SEED_COUNT"

    local seeded_count
    seeded_count="$(s3_object count --prefix "$DB_PREFIX/asset")"
    expect_value "$seeded_count" "$SEED_COUNT" "The bucket holds more than one listing page of objects"

    # --- 2. The app's own listing enumerates all of them. ---

    # Every seeded object is unreferenced, so find-orphans has to walk the whole listing. A report of
    # 1000 here is exactly the truncated-at-one-page failure this test exists to catch.
    local orphans_output
    invoke_command "Find orphans across more than one listing page" \
        "$(get_cli_command) find-orphans --db \"$s3_db\" --yes" 0 "orphans_output"

    # The command's summary line reads "Found <n> orphaned file(s) ..." (apps/cli/src/cmd/find-orphans.ts).
    local orphan_count
    orphan_count="$(parse_numeric "$orphans_output" "Found")"
    expect_value "$orphan_count" "$SEED_COUNT" "The app's listing enumerated every object past the first page"

    test_passed
}

test_s3_pagination "$TEST_NUMBER"
