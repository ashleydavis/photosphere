#!/bin/bash

# Photosphere CLI Write Lock Smoke Tests
# Tests write lock functionality with parallel processes

set -e

# Disable colors for consistent output parsing
export NO_COLOR=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_FILES_DIR="./test/tmp/write-lock-files"
PROCESS_OUTPUT_DIR="./test/tmp/write-lock-outputs"

# Default values
DEBUG_MODE=false
NUM_PROCESSES=4
NUM_ITERATIONS=6
SLEEP_MIN=0.1
SLEEP_MAX=2.0
SIMULATE_FAILURE=false
USE_CLOUD=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG_MODE=true
            shift
            ;;
        --processes)
            NUM_PROCESSES="$2"
            shift 2
            ;;
        --iterations)
            NUM_ITERATIONS="$2"
            shift 2
            ;;
        --sleep-range)
            IFS='-' read -r SLEEP_MIN SLEEP_MAX <<< "$2"
            shift 2
            ;;
        --simulate-failure)
            SIMULATE_FAILURE=true
            shift
            ;;
        --cloud)
            USE_CLOUD=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--debug] [--processes N] [--iterations N] [--sleep-range MIN-MAX] [--simulate-failure] [--cloud]"
            echo "  --debug       Use bun run start instead of binary"
            echo "  --processes   Number of parallel processes (default: 4)"
            echo "  --iterations  Number of iterations per process (default: 6)"
            echo "  --sleep-range Sleep range in seconds as MIN-MAX (default: 0.1-2.0)"
            echo "  --simulate-failure Enable failure simulation (10% chance during add-file)"
            echo "  --cloud       Use cloud storage (S3) for database instead of local filesystem"
            echo ""
            echo "Cloud Storage Requirements:"
            echo "  When using --cloud, ensure S3 is configured with:"
            echo "  - AWS credentials (via AWS CLI, environment variables, or IAM role)"
            echo "  - S3 bucket 'photosphere-test-write-lock' exists and is accessible"
            echo "  - Test will use path: s3:photosphere-test-write-lock/write-lock-test"
            echo "  - Run 'psi config' to configure S3 credentials if needed"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Platform detection functions (copied from smoke-tests.sh)
detect_platform() {
    local os="$(uname -s)"
    case "$os" in
        Linux*)     echo "linux";;
        Darwin*)    echo "mac";;
        CYGWIN*|MINGW*|MSYS*) echo "win";;
        *)          echo "unknown";;
    esac
}

detect_architecture() {
    local arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "x64";;
        arm64|aarch64) echo "arm64";;
        *) echo "x64";;  # Default to x64
    esac
}

# Get CLI command based on platform and debug mode
get_cli_command() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "bun run start --"
    else
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        
        case "$platform" in
            "linux")
                echo "./bin/x64/linux/psi"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    echo "./bin/arm64/mac/psi"
                else
                    echo "./bin/x64/mac/psi"
                fi
                ;;
            "win")
                echo "./bin/x64/win/psi.exe"
                ;;
            *)
                echo "./bin/x64/linux/psi"  # Default to linux
                ;;
        esac
    fi
}

# Get database directory based on cloud mode
get_test_db_dir() {
    if [ "$USE_CLOUD" = "true" ]; then
        # Use consistent S3 path for write lock tests
        # Format: s3:bucket-name/path (no double slash)
        echo "s3:photosphere-test-write-lock/write-lock-test"
    else
        echo "./test/tmp/write-lock-test-db"
    fi
}

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Global variable to store which ImageMagick convert command to use
IMAGEMAGICK_CONVERT_CMD=""

# Check if required tools are available
check_dependencies() {
    # Check ImageMagick - determine which convert command to use
    if command -v magick &> /dev/null; then
        local magick_output=$(magick --version 2>/dev/null || echo "")
        if [ -n "$magick_output" ]; then
            log_info "ImageMagick 7.x detected (using 'magick')"
            IMAGEMAGICK_CONVERT_CMD="magick"
        else
            log_error "ImageMagick magick command exists but cannot get version"
            exit 1
        fi
    elif command -v convert &> /dev/null; then
        local convert_output=$(convert -version 2>/dev/null | head -1 || echo "")
        if [ -n "$convert_output" ]; then
            log_info "ImageMagick 6.x detected (using 'convert')"
            IMAGEMAGICK_CONVERT_CMD="convert"
        else
            log_error "ImageMagick convert command exists but cannot get version"
            exit 1
        fi
    else
        log_error "ImageMagick not found in system PATH (tried both 'magick' and 'convert')"
        exit 1
    fi
    
    # Check if sha256sum is available
    if ! command -v sha256sum &> /dev/null; then
        log_error "sha256sum is required but not installed"
        exit 1
    fi
    
    # Check S3 configuration if cloud mode is enabled
    if [ "$USE_CLOUD" = "true" ]; then
        log_info "Cloud mode enabled - checking S3 configuration..."
        
        # Check if AWS CLI is available (optional but helpful)
        if ! command -v aws &> /dev/null; then
            log_warning "AWS CLI not found - S3 access will use other credential methods"
        fi
        
        # Check for AWS credentials
        if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -z "$AWS_PROFILE" ] && [ ! -f "$HOME/.aws/credentials" ]; then
            log_warning "No AWS credentials found in environment or ~/.aws/credentials"
            log_warning "Make sure S3 is configured with: psi config"
        fi
        
        log_info "S3 bucket 'photosphere-test-write-lock' will be used for testing"
    fi
}

# Clear S3 test directory
clear_s3_test_directory() {
    if [ "$USE_CLOUD" = "true" ]; then
        log_info "Clearing S3 test directory..."
        
        # Extract bucket and path from S3 URL
        local s3_path="photosphere-test-write-lock/write-lock-test"
        local bucket_name="photosphere-test-write-lock"
        local test_path="write-lock-test"
        
        # Use AWS CLI to clear the test directory
        if command -v aws &> /dev/null; then
            log_info "Using AWS CLI to clear S3 directory: s3://$s3_path"
            
            # List and delete all objects in the test path
            local temp_file="/tmp/s3-objects-to-delete.txt"
            aws s3api list-objects-v2 --bucket "$bucket_name" --prefix "$test_path/" --query 'Contents[].Key' --output text > "$temp_file" 2>/dev/null || true
            
            if [ -s "$temp_file" ]; then
                # Delete objects in batches
                while IFS= read -r object_key; do
                    if [ -n "$object_key" ] && [ "$object_key" != "None" ]; then
                        aws s3api delete-object --bucket "$bucket_name" --key "$object_key" >/dev/null 2>&1 || true
                    fi
                done < "$temp_file"
                log_info "Cleared existing objects from S3 test directory"
            else
                log_info "S3 test directory is already empty"
            fi
            
            rm -f "$temp_file"
        else
            log_warning "AWS CLI not available - cannot clear S3 directory"
            log_warning "Make sure the S3 directory is empty before running the test"
        fi
    fi
}

# Setup test environment
setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Get the test database directory (local or cloud)
    TEST_DB_DIR=$(get_test_db_dir)
    
    # Clean up any existing test directories from previous runs
    if [ "$USE_CLOUD" = "false" ]; then
        rm -rf "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
    else
        rm -rf "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
        log_info "Using cloud database: $TEST_DB_DIR"
        # Clear S3 test directory
        clear_s3_test_directory
    fi
    
    # Create directories (only for local filesystem)
    if [ "$USE_CLOUD" = "false" ]; then
        mkdir -p "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
    else
        mkdir -p "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
    fi
    
    # Initialize database
    log_info "Initializing test database..."
    $(get_cli_command) init --db "$TEST_DB_DIR" --yes --session-id "setup-process"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to initialize database"
        exit 1
    fi
    
    log_success "Test environment setup complete"
}

# Generate a unique PNG file
generate_png_file() {
    local file_path="$1"
    local width=$((100 + RANDOM % 200))
    local height=$((100 + RANDOM % 200))
    local red=$((RANDOM % 256))
    local green=$((RANDOM % 256))
    local blue=$((RANDOM % 256))
    
    # Generate a random colored PNG using ImageMagick
    $IMAGEMAGICK_CONVERT_CMD -size ${width}x${height} "xc:rgb($red,$green,$blue)" "$file_path"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to generate PNG file: $file_path"
        return 1
    fi
    
    return 0
}

# Worker process function
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
        # Random sleep between SLEEP_MIN and SLEEP_MAX seconds
        local sleep_range=$(awk "BEGIN {printf \"%.1f\", $SLEEP_MAX - $SLEEP_MIN}")
        local sleep_time=$(awk "BEGIN {srand(); printf \"%.1f\", rand() * $sleep_range + $SLEEP_MIN}")
        sleep "$sleep_time"
        
        # Generate unique filename
        local timestamp=$(date +%s%N)
        local filename="process_${process_id}_iter_${i}_${timestamp}.png"
        local file_path="$TEST_FILES_DIR/$filename"
        
        # Generate PNG file
        if ! generate_png_file "$file_path"; then
            echo "$timestamp,$filename,GENERATION_FAILED,0,FAILED" >> "$output_file"
            continue
        fi
        
        # Calculate file hash and size
        local file_hash=$(sha256sum "$file_path" | cut -d' ' -f1)
        local file_size=$(stat -c%s "$file_path")
        
        # Add file to database and capture timing and detailed output
        local start_time=$(date +%s%N)
        local add_stdout_file="/tmp/stdout_p${process_id}_i${i}.tmp"
        local add_stderr_file="/tmp/stderr_p${process_id}_i${i}.tmp"
        local add_exit_code=0
        local add_result="SUCCESS"
        local cli_command="$(get_cli_command) add --db \"$TEST_DB_DIR\" \"$file_path\" --verbose --yes --session-id \"process-$process_id-iter-$i\""
        
        # Set failure simulation environment variable if enabled
        if [ "$SIMULATE_FAILURE" = "true" ]; then
            export SIMULATE_FAILURE=add-file
        fi
        
        # Run command and capture stdout/stderr to temporary files
        $(get_cli_command) add --db "$TEST_DB_DIR" "$file_path" --verbose --yes --session-id "process-$process_id-iter-$i" > "$add_stdout_file" 2> "$add_stderr_file"
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
        
        local end_time=$(date +%s%N)
        local duration_ms=$(( (end_time - start_time) / 1000000 ))
        
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

# Cleanup function to kill any orphaned processes
cleanup_processes() {
    if [ ${#background_pids[@]} -gt 0 ]; then
        log_warning "Cleaning up background processes..."
        for pid in "${background_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Terminating process $pid"
                kill "$pid" 2>/dev/null || true
            fi
        done
        # Give processes time to exit gracefully
        sleep 2
        # Force kill any remaining processes
        for pid in "${background_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                log_warning "Force killing process $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi
}

# Set up cleanup trap
background_pids=()
trap cleanup_processes EXIT INT TERM

# Start parallel processes
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

# Validate database integrity and file tracking
validate_results() {
    log_info "Validating database integrity and file tracking..."
    
    # Check database integrity
    log_info "Checking database integrity..."
    local verify_output_file="/tmp/verify_output.log"
    if ! $(get_cli_command) verify --db "$TEST_DB_DIR" --yes > "$verify_output_file" 2>&1; then
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
        local file_path="$TEST_FILES_DIR/$filename"
        
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
        local actual_hash=$(sha256sum "$file_path" | cut -d' ' -f1)
        local actual_size=$(stat -c%s "$file_path")
        
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
        if ! $(get_cli_command) check --db "$TEST_DB_DIR" "$file_path" --yes > /dev/null 2>&1; then
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





# Main test execution
main() {
    echo "============================================================================"
    echo "=== PHOTOSPHERE WRITE LOCK SMOKE TEST ==="
    echo "============================================================================"
    echo "Configuration:"
    echo "  Processes: $NUM_PROCESSES"
    echo "  Iterations per process: $NUM_ITERATIONS"
    echo "  Sleep range: ${SLEEP_MIN}s - ${SLEEP_MAX}s"
    echo "  Debug mode: $DEBUG_MODE"
    echo "  Cloud mode: $USE_CLOUD"
    echo "  CLI command: $(get_cli_command)"
    echo "============================================================================"
    
    # Check dependencies
    check_dependencies
    
    # Setup test environment
    setup_test_environment
    
    # Start parallel processes
    if ! start_parallel_processes; then
        log_error "Parallel processes failed"
        exit 1
    fi
    
    # Clear background_pids since all processes completed successfully
    background_pids=()
    
    # Validate results
    if validate_results; then
        log_success "Write lock smoke test PASSED"
        local exit_code=0
    else
        log_error "Write lock smoke test FAILED"
        local exit_code=1
    fi
    
    
    if [ "$USE_CLOUD" = "true" ]; then
        log_info "Cloud database: $TEST_DB_DIR"
        log_info "Local test data preserved in: $TEST_FILES_DIR, $PROCESS_OUTPUT_DIR"
    else
        log_info "Test data preserved in: $TEST_DB_DIR, $TEST_FILES_DIR, $PROCESS_OUTPUT_DIR"
    fi
    log_info "Process directories: $PROCESS_OUTPUT_DIR/process_*/"
    log_info "Individual iteration logs: $PROCESS_OUTPUT_DIR/process_*/iteration_*.log"
    
    exit $exit_code
}


# Run main function
main "$@"