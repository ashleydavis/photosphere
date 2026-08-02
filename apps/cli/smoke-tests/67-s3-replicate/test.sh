#!/bin/bash
DESCRIPTION="Replicate a database between local storage and S3, both directions"

# Replication over S3 has never been tested. The local replicate tests (17-23) only ever copy between
# two filesystem directories, so every S3 read and write in the replication path is uncovered.
#
# The assertions go through the CLI's own output only: root-hash, database-id and summary. The helper
# functions in lib/functions.sh cannot be used here because they hardcode $TEST_DB_DIR, delete their
# destination, and assert with check_exists against filesystem paths, none of which mean anything for
# an s3: destination.
#
# Matching root hashes are the real assertion. A replica that copied nothing would still report a
# successful replication and an empty-but-valid database, and only the hash comparison catches that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-67}"

# Every local database this test creates goes under a directory named for this process, so running
# the test twice in a row cannot trip over the last run's leftovers. A full suite run clears the whole
# scratch tree up front; a single-test run (`bun run test:cli -- 67`) does not, and `init` refuses a
# directory that already contains a database.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

#
# Prints the aggregate root hash of a database, stripped of colouring and whitespace, so two of them
# can be compared as strings.
# Usage: read_root_hash <db-path>
#
read_root_hash() {
    local db_path="$1"
    $(get_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs
}

#
# Prints the database id of a database, stripped of colouring and whitespace.
# Usage: read_database_id <db-path>
#
read_database_id() {
    local db_path="$1"
    $(get_cli_command) database-id --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs
}

test_s3_replicate() {
    local test_number="$1"
    print_test_header "$test_number" "S3 REPLICATE"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    local source_db="$TEST_DIR/source-db"
    local s3_replica="s3:$S3_EMULATOR_BUCKET/replica"
    local local_replica="$TEST_DIR/local-replica"

    # --- Build the source database on the local filesystem. ---

    invoke_command "Initialize the source database" "$(get_cli_command) init --db $source_db --yes" 0
    populate_db_with_5_files "$source_db"

    local source_hash source_id
    source_hash="$(read_root_hash "$source_db")"
    source_id="$(read_database_id "$source_db")"
    log_info "Source root hash: $source_hash, database id: $source_id"

    local source_summary
    invoke_command "Summarise the source database" "$(get_cli_command) summary --db $source_db --yes" 0 "source_summary"
    local source_file_count
    source_file_count="$(parse_numeric "$source_summary" "Total files:")"
    expect_value "$([ "$source_file_count" -gt 0 ] && echo "yes" || echo "no")" "yes" "The source database has files to replicate"

    # --- 1. Replicate local to S3. ---

    invoke_command "Replicate the local database up to S3" \
        "$(get_cli_command) replicate --db $source_db --dest \"$s3_replica\" --yes" 0

    expect_value "$(read_root_hash "$s3_replica")" "$source_hash" "The S3 replica's root hash matches the source"
    expect_value "$(read_database_id "$s3_replica")" "$source_id" "The S3 replica's database id matches the source"

    local s3_summary
    invoke_command "Summarise the S3 replica" "$(get_cli_command) summary --db \"$s3_replica\" --yes" 0 "s3_summary"
    expect_output_value "$s3_summary" "Total files:" "$source_file_count" "The S3 replica reports the source's file count"

    # --- 2. Replicate S3 back down to a second local directory. ---

    invoke_command "Replicate the S3 database back down to local storage" \
        "$(get_cli_command) replicate --db \"$s3_replica\" --dest $local_replica --yes" 0

    expect_value "$(read_root_hash "$local_replica")" "$source_hash" "The local replica's root hash matches the source"
    expect_value "$(read_database_id "$local_replica")" "$source_id" "The local replica's database id matches the source"

    local local_summary
    invoke_command "Summarise the local replica" "$(get_cli_command) summary --db $local_replica --yes" 0 "local_summary"
    expect_output_value "$local_summary" "Total files:" "$source_file_count" "The local replica reports the source's file count"

    # --- 3. A second replication picks up exactly the newly added file. ---

    # test.webp is the one standard fixture populate_db_with_5_files does not add, so this genuinely
    # adds a sixth file rather than being rejected as a duplicate.
    invoke_command "Add one more file to the source" \
        "$(get_cli_command) add --db $source_db $TEST_FILES_DIR/test.webp --yes" 0

    local updated_hash updated_summary updated_file_count
    updated_hash="$(read_root_hash "$source_db")"
    invoke_command "Summarise the updated source database" "$(get_cli_command) summary --db $source_db --yes" 0 "updated_summary"
    updated_file_count="$(parse_numeric "$updated_summary" "Total files:")"

    invoke_command "Replicate the source up to S3 again" \
        "$(get_cli_command) replicate --db $source_db --dest \"$s3_replica\" --yes" 0

    expect_value "$(read_root_hash "$s3_replica")" "$updated_hash" "The S3 replica's root hash matches after the incremental replication"

    local updated_s3_summary
    invoke_command "Summarise the S3 replica again" "$(get_cli_command) summary --db \"$s3_replica\" --yes" 0 "updated_s3_summary"
    expect_output_value "$updated_s3_summary" "Total files:" "$updated_file_count" "The S3 replica picked up the added file"

    test_passed
}

test_s3_replicate "$TEST_NUMBER"
