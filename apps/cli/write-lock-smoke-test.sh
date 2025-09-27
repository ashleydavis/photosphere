#!/bin/bash

# Photosphere CLI Write Lock Smoke Tests
# Tests write lock functionality with parallel processes

set -e

# Set NODE_ENV to testing for deterministic UUID generation
export NODE_ENV=testing

# Disable colors for consistent output parsing
export NO_COLOR=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DB_DIR="./test/tmp/write-lock-test-db"
TEST_FILES_DIR="./test/tmp/write-lock-files"
PROCESS_OUTPUT_DIR="./test/tmp/write-lock-outputs"

# Default values
DEBUG_MODE=false
NUM_PROCESSES=4
NUM_ITERATIONS=6
SLEEP_MIN=0.1
SLEEP_MAX=2.0

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
        -h|--help)
            echo "Usage: $0 [--debug] [--processes N] [--iterations N] [--sleep-range MIN-MAX]"
            echo "  --debug       Use bun run start instead of binary"
            echo "  --processes   Number of parallel processes (default: 4)"
            echo "  --iterations  Number of iterations per process (default: 6)"
            echo "  --sleep-range Sleep range in seconds as MIN-MAX (default: 0.1-2.0)"
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

# Check if required tools are available
check_dependencies() {
    # Check if convert (ImageMagick) is available for PNG generation
    if ! command -v convert &> /dev/null; then
        log_error "convert (ImageMagick) is required but not installed"
        exit 1
    fi
    
    # Check if sha256sum is available
    if ! command -v sha256sum &> /dev/null; then
        log_error "sha256sum is required but not installed"
        exit 1
    fi
}

# Setup test environment
setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Clean up any existing test directories from previous runs
    rm -rf "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
    
    # Create directories
    mkdir -p "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"
    
    # Initialize database
    log_info "Initializing test database..."
    $(get_cli_command) init --db "$TEST_DB_DIR" --yes
    
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
    convert -size ${width}x${height} "xc:rgb($red,$green,$blue)" "$file_path"
    
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
    echo "# Format: timestamp,filename,hash,size_bytes,add_result,lock_contention,duration_ms" >> "$output_file"
    
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
        local add_output
        local add_exit_code=0
        local add_result="SUCCESS"
        local lock_contention="NO"
        
        add_output=$($(get_cli_command) add --db "$TEST_DB_DIR" "$file_path" --verbose --yes 2>&1) || add_exit_code=$?
        
        local end_time=$(date +%s%N)
        local duration_ms=$(( (end_time - start_time) / 1000000 ))
        
        if [ $add_exit_code -ne 0 ]; then
            add_result="FAILED"
            # Check if failure was due to write lock contention
            if echo "$add_output" | grep -q "Failed to acquire write lock"; then
                lock_contention="YES"
            fi
        fi
        
        # Extract lock events from verbose output and save to separate lock log
        local lock_log_file="$PROCESS_OUTPUT_DIR/process_${process_id}_locks.log"
        echo "$add_output" | grep "\[LOCK\]" >> "$lock_log_file" 2>/dev/null || true
        
        # Log the result with enhanced information
        echo "$timestamp,$filename,$file_hash,$file_size,$add_result,$lock_contention,$duration_ms" >> "$output_file"
        
        log_info "Process $process_id: Added $filename ($add_result)"
    done
    
    log_success "Worker process $process_id completed"
}

# Start parallel processes
start_parallel_processes() {
    log_info "Starting $NUM_PROCESSES parallel processes, $NUM_ITERATIONS iterations each"
    
    local pids=()
    
    # Start worker processes in background
    for ((p=1; p<=NUM_PROCESSES; p++)); do
        worker_process "$p" &
        pids+=($!)
    done
    
    # Wait for all processes to complete
    log_info "Waiting for all processes to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid"
        if [ $? -ne 0 ]; then
            log_warning "Process $pid exited with non-zero status"
        fi
    done
    
    log_success "All parallel processes completed"
}

# Validate database integrity and file tracking
validate_results() {
    log_info "Validating database integrity and file tracking..."
    
    # Check database integrity
    log_info "Checking database integrity..."
    if ! $(get_cli_command) verify --db "$TEST_DB_DIR" --yes > /dev/null 2>&1; then
        log_error "Database integrity check failed"
        return 1
    fi
    log_success "Database integrity check passed"
    
    # Collect all tracked files from process outputs and analyze lock contention
    local tracked_files=()
    local successful_adds=0
    local failed_adds=0
    local lock_contentions=0
    local total_duration=0
    local max_duration=0
    
    for ((p=1; p<=NUM_PROCESSES; p++)); do
        local output_file="$PROCESS_OUTPUT_DIR/process_${p}.log"
        if [ -f "$output_file" ]; then
            # Skip comment lines and count results
            while IFS=',' read -r timestamp filename hash size result lock_contention duration_ms; do
                if [[ ! "$timestamp" =~ ^# ]]; then
                    tracked_files+=("$filename:$hash:$size")
                    if [ "$result" = "SUCCESS" ]; then
                        ((successful_adds++))
                    else
                        ((failed_adds++))
                    fi
                    if [ "$lock_contention" = "YES" ]; then
                        ((lock_contentions++))
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
    
    log_info "Tracked files: ${#tracked_files[@]}, Successful: $successful_adds, Failed: $failed_adds"
    log_info "Lock contentions: $lock_contentions, Avg duration: ${avg_duration}ms, Max duration: ${max_duration}ms"
    
    # Verify each successfully tracked file is in the database with correct metadata
    local verification_errors=0
    
    for file_info in "${tracked_files[@]}"; do
        IFS=':' read -r filename expected_hash expected_size <<< "$file_info"
        local file_path="$TEST_FILES_DIR/$filename"
        
        # Skip if file addition failed
        local add_result=$(grep "$filename" "$PROCESS_OUTPUT_DIR"/process_*.log | cut -d',' -f5)
        if [ "$add_result" != "SUCCESS" ]; then
            continue
        fi
        
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
        if ! $(get_cli_command) check --db "$TEST_DB_DIR" "$file_path" --yes > /dev/null 2>&1; then
            log_error "File not found in database: $file_path"
            ((verification_errors++))
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

# Analyze lock events from verbose logs
analyze_lock_events() {
    local lock_analysis_file="$PROCESS_OUTPUT_DIR/lock_analysis.txt"
    
    echo "============================================================================" > "$lock_analysis_file"
    echo "=== WRITE LOCK EVENT ANALYSIS ===" >> "$lock_analysis_file"
    echo "============================================================================" >> "$lock_analysis_file"
    echo "Test Configuration:" >> "$lock_analysis_file"
    echo "  Processes: $NUM_PROCESSES" >> "$lock_analysis_file"
    echo "  Iterations per process: $NUM_ITERATIONS" >> "$lock_analysis_file"
    echo "  Sleep range: ${SLEEP_MIN}s - ${SLEEP_MAX}s" >> "$lock_analysis_file"
    echo "" >> "$lock_analysis_file"
    
    # Combine all lock logs
    local combined_locks="$PROCESS_OUTPUT_DIR/combined_locks.log"
    cat "$PROCESS_OUTPUT_DIR"/process_*_locks.log > "$combined_locks" 2>/dev/null || true
    
    if [ ! -s "$combined_locks" ]; then
        echo "No lock events found in verbose output" >> "$lock_analysis_file"
        return
    fi
    
    # Parse lock events
    local total_attempts=0
    local total_successes=0
    local total_failures=0
    local total_releases=0
    
    # Count events by type
    total_attempts=$(grep -c "ACQUIRE_ATTEMPT" "$combined_locks" 2>/dev/null || echo 0)
    total_successes=$(grep -c "ACQUIRE_SUCCESS" "$combined_locks" 2>/dev/null || echo 0)
    total_failures=$(grep -c "ACQUIRE_FAILED" "$combined_locks" 2>/dev/null || echo 0)
    total_releases=$(grep -c "RELEASE_SUCCESS" "$combined_locks" 2>/dev/null || echo 0)
    
    echo "Lock Event Summary:" >> "$lock_analysis_file"
    echo "  Total lock attempts: $total_attempts" >> "$lock_analysis_file"
    echo "  Successful acquisitions: $total_successes" >> "$lock_analysis_file"
    echo "  Failed acquisitions: $total_failures" >> "$lock_analysis_file"
    echo "  Successful releases: $total_releases" >> "$lock_analysis_file"
    
    if [ $total_attempts -gt 0 ]; then
        local success_rate=$((total_successes * 100 / total_attempts))
        echo "  Lock success rate: ${success_rate}%" >> "$lock_analysis_file"
    fi
    echo "" >> "$lock_analysis_file"
    
    # Analyze lock contention patterns
    echo "Lock Contention Analysis:" >> "$lock_analysis_file"
    
    # Count different failure types
    local failed_exists=$(grep -c "ACQUIRE_FAILED_EXISTS" "$combined_locks" 2>/dev/null || echo 0)
    local failed_race=$(grep -c "ACQUIRE_FAILED_RACE" "$combined_locks" 2>/dev/null || echo 0)
    local failed_error=$(grep -c "ACQUIRE_FAILED_ERROR" "$combined_locks" 2>/dev/null || echo 0)
    
    echo "  Lock already exists: $failed_exists" >> "$lock_analysis_file"
    echo "  Race condition failures: $failed_race" >> "$lock_analysis_file"
    echo "  Other errors: $failed_error" >> "$lock_analysis_file"
    echo "" >> "$lock_analysis_file"
    
    # Analyze lock hold durations
    echo "Lock Hold Duration Analysis:" >> "$lock_analysis_file"
    analyze_lock_hold_durations "$combined_locks" >> "$lock_analysis_file"
    echo "" >> "$lock_analysis_file"
    
    # Per-process analysis
    echo "Per-Process Lock Activity:" >> "$lock_analysis_file"
    for ((p=1; p<=NUM_PROCESSES; p++)); do
        local process_lock_file="$PROCESS_OUTPUT_DIR/process_${p}_locks.log"
        if [ -f "$process_lock_file" ] && [ -s "$process_lock_file" ]; then
            local p_attempts=$(grep -c "ACQUIRE_ATTEMPT" "$process_lock_file" 2>/dev/null || echo 0)
            local p_successes=$(grep -c "ACQUIRE_SUCCESS" "$process_lock_file" 2>/dev/null || echo 0)
            local p_failures=$(grep -c "ACQUIRE_FAILED" "$process_lock_file" 2>/dev/null || echo 0)
            local p_releases=$(grep -c "RELEASE_SUCCESS" "$process_lock_file" 2>/dev/null || echo 0)
            
            echo "  Process $p: $p_attempts attempts, $p_successes successes, $p_failures failures, $p_releases releases" >> "$lock_analysis_file"
        else
            echo "  Process $p: No lock events recorded" >> "$lock_analysis_file"
        fi
    done
    
    echo "" >> "$lock_analysis_file"
    echo "Lock event analysis saved to: $lock_analysis_file" | tee -a "$lock_analysis_file"
    
    # Display key metrics to user
    log_info "Lock Event Analysis:"
    log_info "  Lock attempts: $total_attempts, Successes: $total_successes, Failures: $total_failures"
    log_info "  Contention events: exists=$failed_exists, race=$failed_race, errors=$failed_error"
    log_info "  Analysis saved to: $lock_analysis_file"
}

# Analyze lock hold durations by matching acquire/release pairs
analyze_lock_hold_durations() {
    local lock_file="$1"
    
    # Extract acquire and release events with timestamps and process IDs
    local temp_acquire="/tmp/acquire_events.tmp"
    local temp_release="/tmp/release_events.tmp"
    
    grep "ACQUIRE_SUCCESS" "$lock_file" | sed 's/\[LOCK\] //' | awk -F',' '{print $1 "," $3 "," $5}' > "$temp_acquire" 2>/dev/null || true
    grep "RELEASE_SUCCESS" "$lock_file" | sed 's/\[LOCK\] //' | awk -F',' '{print $1 "," $3 "," $5}' > "$temp_release" 2>/dev/null || true
    
    local total_holds=0
    local total_duration=0
    local min_duration=999999999
    local max_duration=0
    
    # Match acquire/release pairs by process ID and calculate durations
    while IFS=',' read -r acquire_time process_id file_path; do
        # Skip empty or malformed lines
        if [ -z "$acquire_time" ] || [ -z "$process_id" ]; then
            continue
        fi
        
        # Validate acquire_time is numeric
        if ! [[ "$acquire_time" =~ ^[0-9]+$ ]]; then
            continue
        fi
        
        # Find corresponding release for same process and file
        local release_time=$(grep "$process_id.*$file_path" "$temp_release" | head -1 | cut -d',' -f1)
        
        # Validate release_time is numeric and non-empty
        if [ -n "$release_time" ] && [[ "$release_time" =~ ^[0-9]+$ ]] && [ "$release_time" -gt "$acquire_time" ]; then
            local duration=$((release_time - acquire_time))
            total_duration=$((total_duration + duration))
            ((total_holds++))
            
            if [ $duration -lt $min_duration ]; then
                min_duration=$duration
            fi
            if [ $duration -gt $max_duration ]; then
                max_duration=$duration
            fi
        fi
    done < "$temp_acquire"
    
    # Clean up temp files
    rm -f "$temp_acquire" "$temp_release"
    
    if [ $total_holds -gt 0 ]; then
        local avg_duration=$((total_duration / total_holds))
        echo "  Total lock holds: $total_holds"
        echo "  Average hold duration: ${avg_duration}ms"
        echo "  Minimum hold duration: ${min_duration}ms"
        echo "  Maximum hold duration: ${max_duration}ms"
    else
        echo "  No complete acquire/release pairs found"
    fi
}

# Generate write lock contention summary
generate_lock_summary() {
    local summary_file="$PROCESS_OUTPUT_DIR/write_lock_summary.txt"
    
    echo "============================================================================" > "$summary_file"
    echo "=== WRITE LOCK CONTENTION SUMMARY ===" >> "$summary_file"
    echo "============================================================================" >> "$summary_file"
    echo "Test Configuration:" >> "$summary_file"
    echo "  Processes: $NUM_PROCESSES" >> "$summary_file"
    echo "  Iterations per process: $NUM_ITERATIONS" >> "$summary_file"
    echo "  Sleep range: ${SLEEP_MIN}s - ${SLEEP_MAX}s" >> "$summary_file"
    echo "" >> "$summary_file"
    
    # Aggregate statistics across all processes
    local total_operations=0
    local total_successes=0
    local total_failures=0
    local total_lock_contentions=0
    local total_duration=0
    local max_duration=0
    local operations_over_3s=0
    
    for ((p=1; p<=NUM_PROCESSES; p++)); do
        local output_file="$PROCESS_OUTPUT_DIR/process_${p}.log"
        if [ -f "$output_file" ]; then
            while IFS=',' read -r timestamp filename hash size result lock_contention duration_ms; do
                if [[ ! "$timestamp" =~ ^# ]]; then
                    ((total_operations++))
                    if [ "$result" = "SUCCESS" ]; then
                        ((total_successes++))
                    else
                        ((total_failures++))
                    fi
                    if [ "$lock_contention" = "YES" ]; then
                        ((total_lock_contentions++))
                    fi
                    if [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ]; then
                        total_duration=$((total_duration + duration_ms))
                        if [ "$duration_ms" -gt "$max_duration" ]; then
                            max_duration=$duration_ms
                        fi
                        # Count operations taking over 3 seconds (likely lock waits)
                        if [ "$duration_ms" -gt 3000 ]; then
                            ((operations_over_3s++))
                        fi
                    fi
                fi
            done < "$output_file"
        fi
    done
    
    local avg_duration=0
    local success_rate=0
    local lock_contention_rate=0
    
    if [ $total_operations -gt 0 ]; then
        avg_duration=$((total_duration / total_operations))
        success_rate=$((total_successes * 100 / total_operations))
        lock_contention_rate=$((total_lock_contentions * 100 / total_operations))
    fi
    
    echo "Overall Statistics:" >> "$summary_file"
    echo "  Total operations: $total_operations" >> "$summary_file"
    echo "  Successful operations: $total_successes" >> "$summary_file"
    echo "  Failed operations: $total_failures" >> "$summary_file"
    echo "  Success rate: ${success_rate}%" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "Write Lock Contention:" >> "$summary_file"
    echo "  Explicit lock contentions: $total_lock_contentions" >> "$summary_file"
    echo "  Lock contention rate: ${lock_contention_rate}%" >> "$summary_file"
    echo "  Operations over 3s (likely lock waits): $operations_over_3s" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "Timing Analysis:" >> "$summary_file"
    echo "  Average operation duration: ${avg_duration}ms" >> "$summary_file"
    echo "  Maximum operation duration: ${max_duration}ms" >> "$summary_file"
    echo "" >> "$summary_file"
    
    # Per-process breakdown
    echo "Per-Process Breakdown:" >> "$summary_file"
    for ((p=1; p<=NUM_PROCESSES; p++)); do
        local output_file="$PROCESS_OUTPUT_DIR/process_${p}.log"
        if [ -f "$output_file" ]; then
            local p_operations=0
            local p_successes=0
            local p_failures=0
            local p_lock_contentions=0
            local p_total_duration=0
            local p_max_duration=0
            
            while IFS=',' read -r timestamp filename hash size result lock_contention duration_ms; do
                if [[ ! "$timestamp" =~ ^# ]]; then
                    ((p_operations++))
                    if [ "$result" = "SUCCESS" ]; then
                        ((p_successes++))
                    else
                        ((p_failures++))
                    fi
                    if [ "$lock_contention" = "YES" ]; then
                        ((p_lock_contentions++))
                    fi
                    if [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ]; then
                        p_total_duration=$((p_total_duration + duration_ms))
                        if [ "$duration_ms" -gt "$p_max_duration" ]; then
                            p_max_duration=$duration_ms
                        fi
                    fi
                fi
            done < "$output_file"
            
            local p_avg_duration=0
            if [ $p_operations -gt 0 ]; then
                p_avg_duration=$((p_total_duration / p_operations))
            fi
            
            echo "  Process $p: $p_successes/$p_operations successful, $p_lock_contentions lock contentions, avg ${p_avg_duration}ms, max ${p_max_duration}ms" >> "$summary_file"
        fi
    done
    
    echo "" >> "$summary_file"
    echo "Lock contention data saved to: $summary_file" | tee -a "$summary_file"
    
    # Display summary to user
    log_info "Write lock contention summary:"
    log_info "  Total operations: $total_operations"
    log_info "  Success rate: ${success_rate}%"
    log_info "  Lock contentions: $total_lock_contentions (${lock_contention_rate}%)"
    log_info "  Long operations (>3s): $operations_over_3s"
    log_info "  Summary saved to: $summary_file"
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
    echo "  CLI command: $(get_cli_command)"
    echo "============================================================================"
    
    # Check dependencies
    check_dependencies
    
    # Setup test environment
    setup_test_environment
    
    # Start parallel processes
    start_parallel_processes
    
    # Validate results
    if validate_results; then
        log_success "Write lock smoke test PASSED"
        local exit_code=0
    else
        log_error "Write lock smoke test FAILED"
        local exit_code=1
    fi
    
    # Analyze lock events from verbose logs (don't let this affect exit code)
    analyze_lock_events || true
    
    # Generate write lock contention summary (don't let this affect exit code)
    generate_lock_summary || true
    
    log_info "Test data preserved in: $TEST_DB_DIR, $TEST_FILES_DIR, $PROCESS_OUTPUT_DIR"
    
    exit $exit_code
}


# Run main function
main "$@"