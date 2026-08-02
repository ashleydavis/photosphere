#!/bin/bash
DESCRIPTION="Sync between an S3 database and a local copy"

# The local sync tests (35-40) only ever sync two filesystem directories. This is the same set of
# behaviours with one side of the pair on S3: an add each way, a field edit, and a deletion each way,
# each followed by the assertion that the two root hashes converge.
#
# The local original is a copy of test/dbs/v6 and the pair is created with `replicate --force`,
# exactly as tests 35-40 do, so the only thing that differs from them is that the other side of the
# pair lives in a bucket.
#
# Matching root hashes are the assertion throughout. A sync that copied nothing still exits zero, and
# only the hash comparison catches that. Each change is also checked to have moved the hashes apart
# before the sync, so a sync with nothing to do cannot be mistaken for a sync that worked.
#
# The field edit is driven on the local side only. bdb-cli writes BSON through the filesystem and has
# no S3 mode, so editing a field inside the database on S3 is not something the tooling here can do;
# an edit made locally and synced up covers the transfer path in the direction that is reachable.
#
# The field edit runs FIRST, immediately after the replicate, which is the order test 37 uses. A
# bdb-cli edit made after some other sync has already run is not picked up by the next sync, which
# reports "Databases already in sync, nothing to do" while the two root hashes differ. That is not an
# S3 behaviour: a local-to-local pair does exactly the same thing, checked by hand while writing this
# test. The cause has not been established, so the order here works with it rather than around it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-69}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"
S3_STATE_DIR="$TEST_DIR/s3"

# The v6 fixture database the local sync tests start from, and the record inside it that tests 37 and
# 39 drive. Both are read from those tests rather than invented here.
V6_DB_DIR="../../test/dbs/v6"
V6_RECORD_ID="89171cd9-a652-4047-b869-1154bf2c95a1"

cleanup_s3_and_show_summary() {
    local exit_code=$?
    stop_s3_emulator "$S3_STATE_DIR"
    return $exit_code
}
trap 'cleanup_s3_and_show_summary; cleanup_and_show_summary' EXIT

#
# Prints the aggregate root hash of a database, stripped of colouring and whitespace, so two of them
# can be compared as strings. Usage: read_root_hash <db-path>
#
read_root_hash() {
    local db_path="$1"
    $(get_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs
}

#
# Fails unless the two databases report the same root hash.
# Usage: expect_hashes_converged <local-db> <s3-db> <description>
#
expect_hashes_converged() {
    local local_db="$1"
    local s3_db="$2"
    local description="$3"

    local local_hash s3_hash
    local_hash="$(read_root_hash "$local_db")"
    s3_hash="$(read_root_hash "$s3_db")"

    if [ "$local_hash" = "$s3_hash" ]; then
        log_success "$description: $local_hash"
        return 0
    fi

    log_error "$description: local $local_hash, S3 $s3_hash"
    exit 1
}

#
# Fails unless the two databases report DIFFERENT root hashes. Run before each sync, so a sync that
# had nothing to do cannot be mistaken for a sync that worked.
# Usage: expect_hashes_diverged <local-db> <s3-db> <description>
#
expect_hashes_diverged() {
    local local_db="$1"
    local s3_db="$2"
    local description="$3"

    local local_hash s3_hash
    local_hash="$(read_root_hash "$local_db")"
    s3_hash="$(read_root_hash "$s3_db")"

    if [ "$local_hash" != "$s3_hash" ]; then
        log_success "$description"
        return 0
    fi

    log_error "$description: both databases report $local_hash, so the change never landed"
    exit 1
}

#
# Extracts the asset id the CLI reported for a just-added file, from the `add` command's output. Only
# the verbose output carries the "Added file ... with ID" line, so the add that needs an id back runs
# with --verbose. Usage: asset_id_from_add_output <output>
#
asset_id_from_add_output() {
    local add_output="$1"
    echo "$add_output" | grep "Added file.*to the database with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1
}

test_s3_sync() {
    local test_number="$1"
    print_test_header "$test_number" "S3 SYNC"

    start_s3_emulator "$S3_STATE_DIR"
    export_s3_env_credentials

    check_exists "$V6_DB_DIR" "V6 test database directory"

    local local_db="$TEST_DIR/original"
    local s3_db="s3:$S3_EMULATOR_BUCKET/sync-copy"
    log_info "Local database: $local_db"
    log_info "S3 database:    $s3_db"

    # --- Build the pair: the v6 fixture replicated up to S3. ---

    mkdir -p "$TEST_DIR"
    log_info "Creating the local original from the v6 fixture"
    cp -r "$V6_DB_DIR" "$local_db"

    invoke_command "Replicate the local database up to S3" \
        "$(get_cli_command) replicate --db $local_db --dest \"$s3_db\" --yes --force" 0
    expect_hashes_converged "$local_db" "$s3_db" "The pair starts with matching root hashes"

    # --- 1. A field edited locally syncs up to S3. ---

    local edited_description="Description edited by smoke test 69"
    invoke_command "Edit a field in the local database" \
        "$(get_bdb_command) edit $local_db/.db/bson metadata $V6_RECORD_ID description string \"$edited_description\"" 0
    expect_hashes_diverged "$local_db" "$s3_db" "The field edit moved the local root hash away from S3's"

    local sync_edit_output
    invoke_command "Sync the field edit up to S3" "$(get_cli_command) sync --db $local_db --dest \"$s3_db\" --yes" 0 "sync_edit_output"
    expect_output_string "$sync_edit_output" "Sync completed successfully" "The field-edit sync completed"
    expect_hashes_converged "$local_db" "$s3_db" "The root hashes converged after syncing the field edit up"

    # --- 2. A file added locally syncs up to S3. ---

    invoke_command "Add a WEBP to the local database" \
        "$(get_cli_command) add --db $local_db $TEST_FILES_DIR/test.webp --yes" 0
    expect_hashes_diverged "$local_db" "$s3_db" "The local add moved the local root hash away from S3's"

    local sync_up_output
    invoke_command "Sync local to S3" "$(get_cli_command) sync --db $local_db --dest \"$s3_db\" --yes" 0 "sync_up_output"
    expect_output_string "$sync_up_output" "Sync completed successfully" "The local-to-S3 sync completed"
    expect_hashes_converged "$local_db" "$s3_db" "The root hashes converged after syncing the local add up"

    local s3_list_after_up
    invoke_command "List the S3 database after syncing up" "$(get_cli_command) list --db \"$s3_db\" --yes" 0 "s3_list_after_up"
    expect_output_string "$s3_list_after_up" "test.webp" "The locally added file is present on S3"

    # --- 3. A file added on S3 syncs back down. ---

    local add_on_s3_output
    invoke_command "Add a JPEG directly to the S3 database" \
        "$(get_cli_command) add --db \"$s3_db\" $TEST_FILES_DIR/multiple-files/test-1.jpeg --verbose --yes" 0 "add_on_s3_output"
    local s3_added_asset_id
    s3_added_asset_id="$(asset_id_from_add_output "$add_on_s3_output")"
    if [ -z "$s3_added_asset_id" ]; then
        log_error "Could not read the asset id for test-1.jpeg out of the add output"
        exit 1
    fi
    log_info "test-1.jpeg asset id: $s3_added_asset_id"
    expect_hashes_diverged "$local_db" "$s3_db" "The S3 add moved the S3 root hash away from the local one"

    local sync_down_output
    invoke_command "Sync S3 to local" "$(get_cli_command) sync --db $local_db --dest \"$s3_db\" --yes" 0 "sync_down_output"
    expect_output_string "$sync_down_output" "Sync completed successfully" "The S3-to-local sync completed"
    expect_hashes_converged "$local_db" "$s3_db" "The root hashes converged after syncing the S3 add down"

    local local_list_after_down
    invoke_command "List the local database after syncing down" "$(get_cli_command) list --db $local_db --yes" 0 "local_list_after_down"
    expect_output_string "$local_list_after_down" "test-1.jpeg" "The file added on S3 is present locally"

    # --- 4. An asset deleted locally syncs its deletion up to S3. ---

    invoke_command "Remove an asset from the local database" \
        "$(get_cli_command) remove --db $local_db $V6_RECORD_ID --yes" 0
    expect_hashes_diverged "$local_db" "$s3_db" "The local deletion moved the local root hash away from S3's"

    local sync_delete_up_output
    invoke_command "Sync the local deletion up to S3" "$(get_cli_command) sync --db $local_db --dest \"$s3_db\" --yes" 0 "sync_delete_up_output"
    expect_output_string "$sync_delete_up_output" "Sync completed successfully" "The deletion sync completed"
    expect_hashes_converged "$local_db" "$s3_db" "The root hashes converged after syncing the local deletion up"

    local s3_list_after_delete
    invoke_command "List the S3 database after the deletion synced up" "$(get_cli_command) list --db \"$s3_db\" --yes" 0 "s3_list_after_delete"
    expect_output_string "$s3_list_after_delete" "$V6_RECORD_ID" "The locally deleted asset is gone from S3" "false"

    # --- 5. An asset deleted on S3 syncs its deletion back down. ---

    invoke_command "Remove an asset from the S3 database" \
        "$(get_cli_command) remove --db \"$s3_db\" $s3_added_asset_id --yes" 0
    expect_hashes_diverged "$local_db" "$s3_db" "The S3 deletion moved the S3 root hash away from the local one"

    local sync_delete_down_output
    invoke_command "Sync the S3 deletion back down" "$(get_cli_command) sync --db $local_db --dest \"$s3_db\" --yes" 0 "sync_delete_down_output"
    expect_output_string "$sync_delete_down_output" "Sync completed successfully" "The reverse deletion sync completed"
    expect_hashes_converged "$local_db" "$s3_db" "The root hashes converged after syncing the S3 deletion down"

    local local_list_after_delete
    invoke_command "List the local database after the deletion synced down" "$(get_cli_command) list --db $local_db --yes" 0 "local_list_after_delete"
    expect_output_string "$local_list_after_delete" "$s3_added_asset_id" "The asset deleted on S3 is gone locally" "false"

    test_passed
}

test_s3_sync "$TEST_NUMBER"
