#!/bin/bash
DESCRIPTION="Parallel Zig CLI processes add files to one local database, and every file added is in it and verifies"

# Four worker processes each generate a PNG, sleep a random time and add the PNG to the same local
# database, for a fixed number of iterations, all at the same time, so they contend for the
# database's write lock. Afterwards the database must verify, and every file a worker reports as added
# must still match the hash and size it had when added and be found in the database.

# The runner exports NODE_ENV=testing, which the standalone script this test was ported from never
# set, so the CLIs here run without it as they did there. For the same reason this test calls neither
# invoke_command nor lib/common.sh's verify_database: both put NODE_ENV=testing back in front of the
# command.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# The tree walk the exit trap stops the workers with.
source "$REPO_ROOT/scripts/lib/process-control.sh"

# Parallel worker processes, and the files each one adds.
NUM_PROCESSES=4
NUM_ITERATIONS=6

# The range of the random sleep before each add, in tenths of a second: 0.1 to 2.0 seconds.
SLEEP_MIN_TENTHS=1
SLEEP_MAX_TENTHS=20

# Where this test keeps its database, its generated files and each worker's output. The database has
# a name of its own rather than lib/common.sh's test database variable, because test_passed and
# test_failed check the database at that path, which the script this test was ported from never did.
WRITE_LOCK_DB_DIR="$TEST_TMP_DIR/write-lock-test-db"
WRITE_LOCK_FILES_DIR="$TEST_TMP_DIR/write-lock-files"
PROCESS_OUTPUT_DIR="$TEST_TMP_DIR/write-lock-outputs"

# Every worker this test backgrounds, so a run that ends early takes them with it.
background_pids=()

# Prints the current time in milliseconds, for each add's timestamp and duration. EPOCHREALTIME
# (bash 5) gives microseconds; the bash 3.2 macOS ships lacks it, and there whole seconds from date are
# the best available.
current_milliseconds() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local epoch_microseconds="${EPOCHREALTIME/[.,]/}"
        echo $((10#$epoch_microseconds / 1000))
    else
        echo $(($(date +%s) * 1000))
    fi
}

# Runs psi verify with the Zig CLI on a database it has just created or modified, and fails the test
# unless it passes, so the integrity of every database the test writes is checked.
#
# This replaces lib/common.sh's verify_database for this test alone. That one runs through invoke_command,
# which puts NODE_ENV=testing in front of the command, and the script this test was ported from ran
# the verify without it.
# Usage: verify_database <database>
verify_database() {
    local database_dir="$1"
    log_info "Verifying $database_dir"
    if ! $(get_zig_cli_command) verify --db "$database_dir" --yes; then
        test_failed "psi verify fails on $database_dir"
    fi
}

# Prints the SHA-256 of a file: sha256sum where it exists, otherwise shasum, as on macOS
sha256_of_file() {
    local file_path="$1"

    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$file_path" | cut -d ' ' -f 1
    else
        shasum -a 256 "$file_path" | cut -d ' ' -f 1
    fi
}

# Fails the test unless sha256sum or shasum (which macOS has instead) is available. The runner checks
# ImageMagick before any test runs.
check_dependencies() {
    if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null; then
        test_failed "sha256sum or shasum is required but neither is installed"
    fi
}

# Creates the test's directories and the database every worker adds to, and verifies the database.
setup_test_environment() {
    log_info "Setting up test environment..."

    # Create directories
    mkdir -p "$WRITE_LOCK_DB_DIR" "$WRITE_LOCK_FILES_DIR" "$PROCESS_OUTPUT_DIR"

    # Initialize database
    log_info "Initializing test database..."
    if ! $(get_zig_cli_command) init --db "$WRITE_LOCK_DB_DIR" --yes --session-id "setup-process"; then
        test_failed "Failed to initialize database"
    fi
    verify_database "$WRITE_LOCK_DB_DIR"

    log_success "Test environment setup complete"
}

# One worker: for each iteration, sleeps a random time, generates a PNG and adds it to the database,
# writing the file's hash, size, the add's result and its duration to the worker's output file, and
# its stdout, stderr and lock events to per-iteration logs. Returns 1 after ten failed adds in a row.
# Usage: worker_process <process number>
worker_process() {
    local process_id="$1"
    local output_file="$PROCESS_OUTPUT_DIR/process_${process_id}.log"

    log_info "Starting worker process $process_id"

    # Initialize process output file
    echo "# Process $process_id output" > "$output_file"
    echo "# Format: timestamp,filename,hash,size_bytes,add_result,duration_ms" >> "$output_file"

    # Create subdirectory for this process
    local process_dir="$PROCESS_OUTPUT_DIR/process_${process_id}"
    mkdir -p "$process_dir"

    # Initialize summary file for this process (kept for backwards compatibility)
    local detailed_output_file="$PROCESS_OUTPUT_DIR/process_${process_id}_detailed.log"
    echo "# Process $process_id detailed output and errors" > "$detailed_output_file"
    echo "# Each iteration shows: command, exit code, stdout, stderr" >> "$detailed_output_file"
    echo "# Individual iteration files are stored in: $process_dir/" >> "$detailed_output_file"

    # Track consecutive failures for early abort
    local consecutive_failures=0
    local max_consecutive_failures=10

    for ((i=1; i<=NUM_ITERATIONS; i++)); do
        # Random sleep between SLEEP_MIN_TENTHS and SLEEP_MAX_TENTHS tenths of a second
        local sleep_tenths=$((SLEEP_MIN_TENTHS + RANDOM % (SLEEP_MAX_TENTHS - SLEEP_MIN_TENTHS + 1)))
        sleep "$((sleep_tenths / 10)).$((sleep_tenths % 10))"

        # Generate unique filename
        local timestamp=$(current_milliseconds)
        local filename="process_${process_id}_iter_${i}_${timestamp}.png"
        local file_path="$WRITE_LOCK_FILES_DIR/$filename"

        # Generate PNG file
        if ! generate_png_file "$file_path"; then
            echo "$timestamp,$filename,GENERATION_FAILED,0,FAILED" >> "$output_file"
            continue
        fi

        # Calculate file hash and size
        local file_hash=$(sha256_of_file "$file_path")
        local file_size=$(wc -c < "$file_path" | tr -d ' ')

        # Add file to database and capture timing and detailed output
        local start_time=$(current_milliseconds)
        local add_stdout_file="$process_dir/stdout_i${i}.tmp"
        local add_stderr_file="$process_dir/stderr_i${i}.tmp"
        local add_exit_code=0
        local add_result="SUCCESS"
        local cli_command="$(get_zig_cli_command) add --db \"$WRITE_LOCK_DB_DIR\" \"$file_path\" --verbose --yes --session-id \"process-$process_id-iter-$i\""

        # Run command and capture stdout/stderr to temporary files
        $(get_zig_cli_command) add --db "$WRITE_LOCK_DB_DIR" "$file_path" --verbose --yes --session-id "process-$process_id-iter-$i" > "$add_stdout_file" 2> "$add_stderr_file"
        add_exit_code=$?

        # Read captured output
        local add_stdout=""
        local add_stderr=""
        if [ -f "$add_stdout_file" ]; then
            add_stdout=$(cat "$add_stdout_file")
            rm -f "$add_stdout_file"
        fi
        if [ -f "$add_stderr_file" ]; then
            add_stderr=$(cat "$add_stderr_file")
            rm -f "$add_stderr_file"
        fi

        local end_time=$(current_milliseconds)
        local duration_ms=$((end_time - start_time))

        if [ $add_exit_code -ne 0 ]; then
            add_result="FAILED"
            ((consecutive_failures++))
        else
            consecutive_failures=0
        fi

        # Create individual iteration file
        local iteration_file="$process_dir/iteration_${i}.log"
        {
            echo "============================================================================"
            echo "Iteration $i (Process $process_id) - $(date)"
            echo "============================================================================"
            echo "File: $filename"
            echo "Hash: $file_hash"
            echo "Size: $file_size bytes"
            echo "Command: $cli_command"
            echo "Exit Code: $add_exit_code"
            echo "Duration: ${duration_ms}ms"
            echo "Result: $add_result"
            echo ""
            echo "STDOUT:"
            echo "$add_stdout"
            echo ""
            echo "STDERR:"
            echo "$add_stderr"
            echo ""
        } > "$iteration_file"

        # Also append summary to main detailed log (for backwards compatibility)
        {
            echo "============================================================================"
            echo "Iteration $i (Process $process_id) - $(date) - $add_result (${duration_ms}ms)"
            echo "============================================================================"
            echo "File: $iteration_file"
            echo "Result: $add_result, Duration: ${duration_ms}ms, Exit Code: $add_exit_code"
            if [ "$add_exit_code" -ne 0 ]; then
                echo "FAILED - See $iteration_file for full details"
            fi
            echo ""
        } >> "$detailed_output_file"

        # Extract lock events from verbose output and save to separate lock logs
        local lock_log_file="$PROCESS_OUTPUT_DIR/process_${process_id}_locks.log"
        local iteration_lock_file="$process_dir/iteration_${i}_locks.log"

        # Save lock events to both combined and individual files
        {
            echo "$add_stdout" | grep "\[LOCK\]" 2>/dev/null || true
            echo "$add_stderr" | grep "\[LOCK\]" 2>/dev/null || true
        } | tee -a "$lock_log_file" > "$iteration_lock_file"

        # Log the result with enhanced information
        echo "$timestamp,$filename,$file_hash,$file_size,$add_result,$duration_ms" >> "$output_file"

        log_info "Process $process_id: Added $filename ($add_result)"

        # Check for consecutive failures and abort if threshold reached
        if [ $consecutive_failures -ge $max_consecutive_failures ]; then
            log_error "Process $process_id: Aborting after $consecutive_failures consecutive failures"
            echo "# Process $process_id aborted after $consecutive_failures consecutive failures" >> "$output_file"
            return 1
        fi
    done

    log_success "Worker process $process_id completed"
}

# Stops every worker still running, keeping the exit code it was entered with so the summary that runs
# after it reports the test's own result. Each worker is a shell whose psi and ImageMagick children do
# the work, so the tree has to be taken rather than the recorded pid alone.
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

# Starts every worker in the background, recording each pid as it starts, and waits for them all.
# Returns 1 when any worker exited non-zero.
start_parallel_processes() {
    log_info "Starting $NUM_PROCESSES parallel processes, $NUM_ITERATIONS iterations each"

    local pids=()

    # Start worker processes in background
    for ((p=1; p<=NUM_PROCESSES; p++)); do
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

# Returns 0 when the database verifies and every file a worker reports as added still has the hash
# and size it was added with and is found in the database, and 1 otherwise.
validate_results() {
    log_info "Validating database integrity and file tracking..."

    # Check database integrity
    log_info "Checking database integrity..."
    local verify_output_file="$PROCESS_OUTPUT_DIR/verify_output.log"
    if ! $(get_zig_cli_command) verify --db "$WRITE_LOCK_DB_DIR" --yes > "$verify_output_file" 2>&1; then
        log_error "Database integrity check failed"
        cat "$verify_output_file"
        rm -f "$verify_output_file"
        return 1
    fi
    rm -f "$verify_output_file"
    log_success "Database integrity check passed"

    # Collect all tracked files from process outputs and analyze lock contention
    log_info "Analyzing process outputs from $NUM_PROCESSES processes..."
    local tracked_files=()
    local successful_adds=0
    local failed_adds=0
    local total_duration=0
    local max_duration=0

    for ((p=1; p<=NUM_PROCESSES; p++)); do
        log_info "Processing output from process $p/$NUM_PROCESSES..."
        local output_file="$PROCESS_OUTPUT_DIR/process_${p}.log"
        if [ -f "$output_file" ]; then
            # Skip comment lines and count results
            while IFS=',' read -r timestamp filename hash size result duration_ms; do
                if [[ ! "$timestamp" =~ ^# ]]; then
                    tracked_files+=("$filename:$hash:$size")
                    if [ "$result" = "SUCCESS" ]; then
                        ((successful_adds++))
                    else
                        ((failed_adds++))
                    fi
                    if [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ]; then
                        total_duration=$((total_duration + duration_ms))
                        if [ "$duration_ms" -gt "$max_duration" ]; then
                            max_duration=$duration_ms
                        fi
                    fi
                fi
            done < "$output_file"
        fi
    done

    local avg_duration=0
    if [ "${#tracked_files[@]}" -gt 0 ]; then
        avg_duration=$((total_duration / ${#tracked_files[@]}))
    fi

    # Get lock contention from verbose logs
    local combined_locks="$PROCESS_OUTPUT_DIR/combined_locks.log"
    cat "$PROCESS_OUTPUT_DIR"/process_*_locks.log > "$combined_locks" 2>/dev/null || true
    local lock_contentions=0
    if [ -f "$combined_locks" ]; then
        lock_contentions=$(grep "ACQUIRE_FAILED" "$combined_locks" 2>/dev/null | wc -l)
    fi

    log_info "Tracked files: ${#tracked_files[@]}, Successful: $successful_adds, Failed: $failed_adds"
    log_info "Lock contentions: $lock_contentions, Avg duration: ${avg_duration}ms, Max duration: ${max_duration}ms"

    # Verify each successfully tracked file is in the database with correct metadata
    local verification_errors=0
    local files_to_verify=0

    # Count files that need verification (successful additions only)
    for file_info in "${tracked_files[@]}"; do
        IFS=':' read -r filename expected_hash expected_size <<< "$file_info"
        local add_result=$(grep "$filename" "$PROCESS_OUTPUT_DIR"/process_*.log | cut -d',' -f5)
        if [ "$add_result" = "SUCCESS" ]; then
            ((files_to_verify++))
        fi
    done

    log_info "Verifying $files_to_verify successfully added files..."
    local current_verification=0

    for file_info in "${tracked_files[@]}"; do
        IFS=':' read -r filename expected_hash expected_size <<< "$file_info"
        local file_path="$WRITE_LOCK_FILES_DIR/$filename"

        # Skip if file addition failed
        local add_result=$(grep "$filename" "$PROCESS_OUTPUT_DIR"/process_*.log | cut -d',' -f5)
        if [ "$add_result" != "SUCCESS" ]; then
            continue
        fi

        ((current_verification++))
        log_info "Verifying file $current_verification/$files_to_verify: $filename"

        # Check if file exists
        if [ ! -f "$file_path" ]; then
            log_error "Tracked file not found: $file_path"
            ((verification_errors++))
            continue
        fi

        # Verify file hash and size
        local actual_hash=$(sha256_of_file "$file_path")
        local actual_size=$(wc -c < "$file_path" | tr -d ' ')

        if [ "$actual_hash" != "$expected_hash" ]; then
            log_error "Hash mismatch for $filename: expected $expected_hash, got $actual_hash"
            ((verification_errors++))
        fi

        if [ "$actual_size" != "$expected_size" ]; then
            log_error "Size mismatch for $filename: expected $expected_size, got $actual_size"
            ((verification_errors++))
        fi

        # Check if file is in database
        log_info "  Checking database entry for $filename..."
        if ! $(get_zig_cli_command) check --db "$WRITE_LOCK_DB_DIR" "$file_path" --yes > /dev/null 2>&1; then
            log_error "File not found in database: $file_path"
            ((verification_errors++))
        else
            log_info "  ✓ Database entry verified for $filename"
        fi
    done

    if [ $verification_errors -eq 0 ]; then
        log_success "All file verification checks passed"
        return 0
    else
        log_error "File verification failed with $verification_errors errors"
        return 1
    fi
}

# The test: set up, add files from every worker at once, validate what they added, and verify the
# database once more. A failed validation still runs that verify before the test fails, as the script
# this test was ported from did.
test_write_lock_parallel() {
    echo "============================================================================"
    echo "=== PHOTOSPHERE WRITE LOCK SMOKE TEST ==="
    echo "============================================================================"
    echo "Configuration:"
    echo "  Processes: $NUM_PROCESSES"
    echo "  Iterations per process: $NUM_ITERATIONS"
    echo "  Sleep range: $((SLEEP_MIN_TENTHS / 10)).$((SLEEP_MIN_TENTHS % 10))s - $((SLEEP_MAX_TENTHS / 10)).$((SLEEP_MAX_TENTHS % 10))s"
    echo "  Use binary: ${USE_BINARY:-false}"
    echo "  Zig CLI command: $(get_zig_cli_command)"
    echo "============================================================================"

    # Check dependencies
    check_dependencies

    # Setup test environment
    setup_test_environment

    # Start parallel processes
    if ! start_parallel_processes; then
        test_failed "Parallel processes failed"
    fi

    # Clear background_pids since all processes completed successfully
    background_pids=()

    # Validate results
    local validation_passed="no"
    if validate_results; then
        log_success "Write lock smoke test PASSED"
        validation_passed="yes"
    else
        log_error "Write lock smoke test FAILED"
    fi

    # Verify the database the concurrent writers built.
    verify_database "$WRITE_LOCK_DB_DIR"

    log_info "Test data preserved in: $WRITE_LOCK_DB_DIR, $WRITE_LOCK_FILES_DIR, $PROCESS_OUTPUT_DIR"
    log_info "Process directories: $PROCESS_OUTPUT_DIR/process_*/"
    log_info "Individual iteration logs: $PROCESS_OUTPUT_DIR/process_*/iteration_*.log"

    if [ "$validation_passed" != "yes" ]; then
        test_failed "Write lock smoke test FAILED"
    fi

    test_passed
}

test_write_lock_parallel
