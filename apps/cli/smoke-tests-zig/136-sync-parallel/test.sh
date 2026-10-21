#!/bin/bash
DESCRIPTION="Parallel Zig CLI processes edit and sync four copies of one database until every copy has the same root hash"

# One database and three replicas of it. One worker process per database edits the description of the
# same asset and syncs its database with every other one, all at the same time, for a fixed number of
# iterations. A final round syncs every database with every other one, after which all of them must
# have the same root hash. The TypeScript CLI verifies every database the Zig CLI writes.

# The runner exports NODE_ENV=testing, which the standalone script this test was ported from never
# set, so the CLIs here run without it as they did there. For the same reason this test calls neither
# invoke_command nor lib/common.sh's ts_verify: both put NODE_ENV=testing back in front of the
# command.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# The tree walk the exit trap stops the workers with.
source "$REPO_ROOT/scripts/lib/process-control.sh"

# Total databases (the original and its replicas), and the edit and sync iterations each worker runs.
NUM_REPLICAS=4
NUM_ITERATIONS=10

# Where this test keeps its databases, its generated asset and each worker's output. The database has
# a name of its own rather than lib/common.sh's test database variable, because test_passed and
# test_failed check the database at that path, which the script this test was ported from never did.
SYNC_DB_DIR="$TEST_TMP_DIR/sync-test-db"
SYNC_FILES_DIR="$TEST_TMP_DIR/sync-test-files"
PROCESS_OUTPUT_DIR="$TEST_TMP_DIR/sync-test-outputs"

# Where ts_verify records how long each TypeScript verify took: the file the runner sums.
TS_VERIFY_TIMING_LOG="$TEST_TMP_DIR/ts-verify-milliseconds.log"

# The ID of the asset every worker edits, and the path of every database in the test.
ASSET_ID=""
declare -a DB_PATHS

# Every worker this test backgrounds, so a run that ends early takes them with it.
background_pids=()

# Runs the TypeScript CLI's psi verify on a database the Zig CLI has just created or modified, and
# fails the test unless it passes, so the reference implementation checks the integrity of every
# database the Zig CLI writes. The time it takes is appended to TS_VERIFY_TIMING_LOG.
#
# This replaces lib/common.sh's ts_verify for this test alone. That one runs through invoke_command,
# which puts NODE_ENV=testing in front of the command, and the script this test was ported from ran
# the verify without it.
# Usage: ts_verify <database>
ts_verify() {
    local database_dir="$1"
    local verify_start
    verify_start="$(current_milliseconds)"
    log_info "Verifying $database_dir with the TypeScript CLI"
    if ! $(get_cli_command) verify --db "$database_dir" --yes; then
        test_failed "The TypeScript CLI does not verify $database_dir"
    fi
    record_ts_verify_milliseconds "$TS_VERIFY_TIMING_LOG" "$verify_start"
}

# Generate a random UUID
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen
    else
        # Fallback: generate a simple random string
        cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# Fails the test unless sha256sum (Linux, Windows) or shasum (macOS) is available. The runner checks
# ImageMagick before any test runs.
check_dependencies() {
    if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null; then
        test_failed "sha256sum or shasum is required but not installed"
    fi
}

# Creates the original database, generates a PNG and adds it, recording its ID in ASSET_ID. Each step
# the Zig CLI takes is verified by the TypeScript CLI.
setup_test_environment() {
    log_info "Setting up test environment..."

    # Create directories
    mkdir -p "$SYNC_DB_DIR" "$SYNC_FILES_DIR" "$PROCESS_OUTPUT_DIR"

    # Initialize database
    log_info "Initializing test database..."
    if ! $(get_zig_cli_command) init --db "$SYNC_DB_DIR" --yes --session-id "setup-process"; then
        test_failed "Failed to initialize database"
    fi
    ts_verify "$SYNC_DB_DIR"

    # Generate a test PNG file
    local test_file="$SYNC_FILES_DIR/test.png"
    log_info "Generating test asset..."
    if ! generate_png_file "$test_file"; then
        test_failed "Failed to generate test PNG file"
    fi

    # Add the test asset to the database
    log_info "Adding test asset to database..."
    local add_output
    if ! add_output=$($(get_zig_cli_command) add --db "$SYNC_DB_DIR" "$test_file" --verbose --yes --session-id "setup-process" 2>&1); then
        echo "$add_output"
        test_failed "Failed to add test asset to database"
    fi

    # Extract asset ID from output (declare as global)
    ASSET_ID=$(echo "$add_output" | grep "Added file.*with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$ASSET_ID" ]; then
        echo "Add output:"
        echo "$add_output"
        test_failed "Failed to extract asset ID from add output"
    fi

    log_info "Test asset added with ID: $ASSET_ID"
    ts_verify "$SYNC_DB_DIR"

    log_success "Test environment setup complete"
}

# Replicates the original database into NUM_REPLICAS - 1 replicas, recording every database's path in
# DB_PATHS, original first. Each replica is verified by the TypeScript CLI.
create_replicas() {
    log_info "Creating $NUM_REPLICAS replica databases..."

    # Create array to store database paths (declare as global)
    DB_PATHS=("$SYNC_DB_DIR")

    # Create replica databases
    for ((i=1; i<NUM_REPLICAS; i++)); do
        local replica_dir="$SYNC_DB_DIR-replica-$i"
        DB_PATHS+=("$replica_dir")

        log_info "Creating replica $i: $replica_dir"

        # Replicate the original database
        if ! $(get_zig_cli_command) replicate --db "$SYNC_DB_DIR" --dest "$replica_dir" --yes --force > /dev/null 2>&1; then
            test_failed "Failed to create replica $i"
        fi
        ts_verify "$replica_dir"
    done

    log_success "Created $NUM_REPLICAS databases (1 original + $((NUM_REPLICAS-1)) replicas)"
}

# One worker: for each iteration, edits the asset's description in its own database with bdb, checks
# the root hash changed, and syncs its database to every other one. Every outcome is written to the
# worker's output file. A failed step is logged and the worker moves to its next iteration; the final
# root hash comparison is what fails the test.
# Usage: worker_process <index into DB_PATHS>
worker_process() {
    local process_id="$1"
    local db_path="${DB_PATHS[$process_id]}"
    local output_file="$PROCESS_OUTPUT_DIR/process_${process_id}.log"

    log_info "Starting worker process $process_id (database: $db_path)"

    # Initialize process output file
    echo "# Process $process_id output" > "$output_file"
    echo "# Database: $db_path" >> "$output_file"
    echo "# Format: iteration,edit_uuid,hash_before,hash_after,hash_changed,sync_results" >> "$output_file"

    for ((i=1; i<=NUM_ITERATIONS; i++)); do
        # Generate random UUID for description
        local edit_uuid=$(generate_uuid)

        log_info "Process $process_id, iteration $i: Editing description to $edit_uuid"

        # Get root hash before edit
        local hash_before
        hash_before=$($(get_zig_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

        if [ -z "$hash_before" ]; then
            log_error "Process $process_id, iteration $i: Failed to get root hash before edit"
            echo "$i,$edit_uuid,,,HASH_BEFORE_FAILED," >> "$output_file"
            continue
        fi

        # Edit the description field using bdb-cli.
        #
        # The collection root is <database>/.db/bson, which is where the BSON database actually
        # lives. This used to pass <database>/metadata, which is not a database at all: every edit
        # answered "Record not found in collection metadata", the failure was tolerated by the
        # `continue` below, and the suite then passed by comparing four databases that nothing had
        # ever modified.
        #
        # The exit code is taken straight after bdb. It used to be taken after the rm below, so it was
        # the rm's, and a failed edit was never reported.
        local edit_output
        local edit_exit_code=0
        edit_output=$($(get_bdb_command) edit "$db_path/.db/bson" metadata "$ASSET_ID" description string "$edit_uuid" 2>&1) || edit_exit_code=$?

        # bdb writes straight into the BSON database and knows nothing about the database state file
        # one level above it, which is where the application records the content hash. Sync reads that
        # hash first and skips outright when both sides report the same one, so an edit made this way
        # is invisible to it: the whole suite used to sync nothing at all. Removing the state file is
        # how a raw edit says "what is recorded about me is no longer true"; the next write recreates
        # it. Nothing the application itself does needs this, because every write it makes stamps the
        # hash as it goes.
        rm -f "$db_path/.db/state.dat"

        if [ $edit_exit_code -ne 0 ]; then
            log_error "Process $process_id, iteration $i: Failed to edit description"
            echo "$edit_output" >> "$output_file"
            echo "$i,$edit_uuid,$hash_before,,EDIT_FAILED," >> "$output_file"
            continue
        fi

        # Get root hash after edit
        local hash_after
        hash_after=$($(get_zig_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

        if [ -z "$hash_after" ]; then
            log_error "Process $process_id, iteration $i: Failed to get root hash after edit"
            echo "$i,$edit_uuid,$hash_before,,HASH_AFTER_FAILED," >> "$output_file"
            continue
        fi

        # Verify root hash changed after edit
        if [ "$hash_before" = "$hash_after" ]; then
            log_error "Process $process_id, iteration $i: Root hash did not change after edit (expected different)"
            log_error "  Hash before: $hash_before"
            log_error "  Hash after:  $hash_after"
            echo "$i,$edit_uuid,$hash_before,$hash_after,NO," >> "$output_file"
            continue
        else
            log_info "Process $process_id, iteration $i: Root hash changed (before: ${hash_before:0:8}..., after: ${hash_after:0:8}...)"
        fi

        # Sync with each of the other databases
        local sync_results=""
        for ((j=0; j<NUM_REPLICAS; j++)); do
            if [ $j -ne $process_id ]; then
                local other_db="${DB_PATHS[$j]}"
                log_info "Process $process_id, iteration $i: Syncing with database $j ($other_db)"

                # Sync from this database to the other
                local sync_output
                local sync_exit_code=0
                sync_output=$($(get_zig_cli_command) sync --db "$db_path" --dest "$other_db" --yes 2>&1) || sync_exit_code=$?

                if [ $sync_exit_code -eq 0 ]; then
                    sync_results="${sync_results}sync_${j}=OK;"
                else
                    sync_results="${sync_results}sync_${j}=FAIL;"
                    log_error "Process $process_id, iteration $i: Failed to sync with database $j"
                    echo "$sync_output" >> "$output_file"
                fi
            fi
        done

        echo "$i,$edit_uuid,$hash_before,$hash_after,YES,$sync_results" >> "$output_file"
        log_info "Process $process_id, iteration $i: Completed"
    done

    log_success "Worker process $process_id completed"
}

# Stops every worker still running, keeping the exit code it was entered with so the summary that runs
# after it reports the test's own result. Each worker is a shell whose psi and bdb children do the
# work, so the tree has to be taken rather than the recorded pid alone.
cleanup_processes() {
    local exit_code=$?
    if [ ${#background_pids[@]} -gt 0 ]; then
        log_warning "Cleaning up background processes..."
        local pid
        for pid in "${background_pids[@]}"; do
            log_info "Terminating process tree $pid"
            kill_process_tree "$pid"
        done
    fi
    background_pids=()
    return $exit_code
}
trap 'cleanup_processes; cleanup_and_show_summary' EXIT
trap 'cleanup_processes; exit 130' INT
trap 'cleanup_processes; exit 143' TERM

# Starts one worker per database in the background, recording each pid as it starts, and waits for
# them all. Returns 1 when any worker exited non-zero.
start_parallel_processes() {
    log_info "Starting $NUM_REPLICAS parallel processes, $NUM_ITERATIONS iterations each"

    local pids=()

    # Start worker processes in background
    for ((p=0; p<NUM_REPLICAS; p++)); do
        worker_process "$p" &
        local pid=$!
        pids+=($pid)
        background_pids+=($pid)
        log_info "Started worker process $p with PID $pid"
    done

    # Wait for all processes to complete
    log_info "Waiting for all processes to complete..."
    local failed_processes=0
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            log_info "Process $pid completed successfully"
        else
            local exit_code=$?
            log_warning "Process $pid exited with status $exit_code"
            ((failed_processes++))
        fi
    done

    if [ $failed_processes -gt 0 ]; then
        log_error "$failed_processes worker processes failed"
        return 1
    fi

    log_success "All parallel processes completed"
}

# Syncs every database to every other database once. Returns 1 at the first sync that fails.
final_sync_round() {
    log_info "Performing final round of syncing between all databases..."

    # Sync each database with every other database
    for ((i=0; i<NUM_REPLICAS; i++)); do
        for ((j=0; j<NUM_REPLICAS; j++)); do
            if [ $i -ne $j ]; then
                local source_db="${DB_PATHS[$i]}"
                local dest_db="${DB_PATHS[$j]}"
                log_info "Syncing database $i -> $j"

                if ! $(get_zig_cli_command) sync --db "$source_db" --dest "$dest_db" --yes > /dev/null 2>&1; then
                    log_error "Failed to sync database $i -> $j"
                    return 1
                fi
            fi
        done
    done

    log_success "Final sync round completed"
}

# Returns 0 when every replica has the original database's root hash, and 1 when any root hash cannot
# be read or differs.
verify_root_hashes() {
    log_info "Verifying all databases have the same root hash..."

    local original_hash
    original_hash=$($(get_zig_cli_command) root-hash --db "${DB_PATHS[0]}" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

    if [ -z "$original_hash" ]; then
        log_error "Failed to get root hash from original database"
        return 1
    fi

    log_info "Original database root hash: $original_hash"

    # Check each replica
    for ((i=1; i<NUM_REPLICAS; i++)); do
        local replica_hash
        replica_hash=$($(get_zig_cli_command) root-hash --db "${DB_PATHS[$i]}" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)

        if [ -z "$replica_hash" ]; then
            log_error "Failed to get root hash from replica $i"
            return 1
        fi

        log_info "Replica $i root hash: $replica_hash"

        if [ "$original_hash" != "$replica_hash" ]; then
            log_error "Root hash mismatch: original ($original_hash) != replica $i ($replica_hash)"
            return 1
        fi
    done

    log_success "All databases have the same root hash: $original_hash"
    return 0
}

# The test: set up, replicate, edit and sync in parallel, a final sync round, then every root hash
# must match and every database must verify.
test_sync_parallel() {
    echo "============================================================================"
    echo "=== PHOTOSPHERE SYNC SMOKE TEST ==="
    echo "============================================================================"
    echo "Configuration:"
    echo "  Total databases: $NUM_REPLICAS"
    echo "  Iterations per process: $NUM_ITERATIONS"
    echo "  Use binary: ${USE_BINARY:-false}"
    echo "  CLI command: $(get_cli_command)"
    echo "  Zig CLI command: $(get_zig_cli_command)"
    echo "  BDB command: $(get_bdb_command)"
    echo "============================================================================"

    # Check dependencies
    check_dependencies

    # Setup test environment
    setup_test_environment

    # Create replica databases
    create_replicas

    # Start parallel processes
    if ! start_parallel_processes; then
        test_failed "Parallel processes failed"
    fi

    # Clear background_pids since all processes completed successfully
    background_pids=()

    # Verify every database the Zig CLI edited and synced with the TypeScript CLI, now the processes
    # that were writing to them have finished
    local worked_db
    for worked_db in "${DB_PATHS[@]}"; do
        ts_verify "$worked_db"
    done

    # Final round of syncing
    if ! final_sync_round; then
        test_failed "Final sync round failed"
    fi

    # Verify root hashes
    if ! verify_root_hashes; then
        test_failed "Root hash verification failed"
    fi

    # Verify every database the Zig CLI synced with the TypeScript CLI
    local synced_db
    for synced_db in "${DB_PATHS[@]}"; do
        ts_verify "$synced_db"
    done

    echo "TypeScript verify: $(count_ts_verify_calls "$TS_VERIFY_TIMING_LOG") calls, $(format_milliseconds_as_seconds "$(sum_ts_verify_milliseconds "$TS_VERIFY_TIMING_LOG")")"

    log_success "Sync smoke test PASSED"
    log_info "Test data preserved in: $SYNC_DB_DIR, $SYNC_FILES_DIR, $PROCESS_OUTPUT_DIR"
    log_info "Process logs: $PROCESS_OUTPUT_DIR/process_*.log"

    test_passed
}

test_sync_parallel
