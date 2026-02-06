#!/bin/bash

# Photosphere CLI Sync Smoke Tests
# Tests syncing functionality with parallel processes

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
TEST_DB_DIR="./test/tmp/sync-test-db"
TEST_FILES_DIR="./test/tmp/sync-test-files"
PROCESS_OUTPUT_DIR="./test/tmp/sync-test-outputs"

# Default: run from code; use --binary for built executable
USE_BINARY=false
NUM_REPLICAS=4
NUM_ITERATIONS=10

# Global variables
ASSET_ID=""
declare -a DB_PATHS

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --binary)
            USE_BINARY=true
            shift
            ;;
        --replicas)
            NUM_REPLICAS="$2"
            shift 2
            ;;
        --iterations)
            NUM_ITERATIONS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--binary] [--replicas N] [--iterations N]"
            echo "  --binary      Use built executable (default: run from code with bun run start)"
            echo "  --replicas    Number of total databases (original + replicas, default: 4)"
            echo "  --iterations  Number of edit/sync iterations per process (default: 10)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Platform detection functions
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

# Get CLI command: default from code; use --binary for built executable
get_cli_command() {
    if [ "$USE_BINARY" = "true" ]; then
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        local cli_path=""
        case "$platform" in
            "linux")
                cli_path="./bin/x64/linux/psi"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    cli_path="./bin/arm64/mac/psi"
                else
                    cli_path="./bin/x64/mac/psi"
                fi
                ;;
            "win")
                cli_path="./bin/x64/win/psi.exe"
                ;;
            *)
                cli_path="./bin/x64/linux/psi"  # Default to linux
                ;;
        esac
        if [ ! -f "$cli_path" ] || [ ! -x "$cli_path" ]; then
            log_error "CLI binary not found or not executable: $cli_path"
            log_error "Please build the binary or run without --binary to use 'bun run start'"
            log_info "To build: cd apps/cli && bun run build"
            exit 1
        fi
        echo "$cli_path"
    else
        echo "bun run start --"
    fi
}

# Get bdb command: default from code; use --binary for built executable
get_bdb_command() {
    if [ "$USE_BINARY" = "true" ]; then
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        local bdb_path=""
        case "$platform" in
            "linux")
                bdb_path="../bdb-cli/bin/x64/linux/bdb"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    bdb_path="../bdb-cli/bin/arm64/mac/bdb"
                else
                    bdb_path="../bdb-cli/bin/x64/mac/bdb"
                fi
                ;;
            "win")
                bdb_path="../bdb-cli/bin/x64/win/bdb.exe"
                ;;
            *)
                bdb_path="../bdb-cli/bin/x64/linux/bdb"  # Default to linux
                ;;
        esac
        if [ ! -f "$bdb_path" ] || [ ! -x "$bdb_path" ]; then
            log_error "BDB CLI binary not found or not executable: $bdb_path"
            log_error "Please build the binary or run without --binary to use 'bun run ../bdb-cli/src/index.ts'"
            log_info "To build: cd apps/bdb-cli && bun run build"
            exit 1
        fi
        echo "$bdb_path"
    else
        echo "bun run ../bdb-cli/src/index.ts"
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

# Generate a random UUID
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen
    elif command -v python3 &> /dev/null; then
        python3 -c "import uuid; print(uuid.uuid4())"
    else
        # Fallback: generate a simple random string
        cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# Check if required tools are available
check_dependencies() {
    # Check ImageMagick - determine which convert command to use
    local imagemagick_cmd=""
    if command -v magick &> /dev/null; then
        local magick_output=$(magick --version 2>/dev/null || echo "")
        if [ -n "$magick_output" ]; then
            log_info "ImageMagick 7.x detected (using 'magick')"
            imagemagick_cmd="magick"
        fi
    elif command -v convert &> /dev/null; then
        local convert_output=$(convert -version 2>/dev/null | head -1 || echo "")
        if [ -n "$convert_output" ]; then
            log_info "ImageMagick 6.x detected (using 'convert')"
            imagemagick_cmd="convert"
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
}

# Generate a unique PNG file
generate_png_file() {
    local file_path="$1"
    local width=$((100 + RANDOM % 200))
    local height=$((100 + RANDOM % 200))
    local red=$((RANDOM % 256))
    local green=$((RANDOM % 256))
    local blue=$((RANDOM % 256))
    
    # Determine which ImageMagick command to use
    local imagemagick_cmd=""
    if command -v magick &> /dev/null; then
        imagemagick_cmd="magick"
    elif command -v convert &> /dev/null; then
        imagemagick_cmd="convert"
    fi
    
    # Generate a random colored PNG using ImageMagick
    $imagemagick_cmd -size ${width}x${height} "xc:rgb($red,$green,$blue)" "$file_path"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to generate PNG file: $file_path"
        return 1
    fi
    
    return 0
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
    $(get_cli_command) init --db "$TEST_DB_DIR" --yes --session-id "setup-process"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to initialize database"
        exit 1
    fi
    
    # Generate a test PNG file
    local test_file="$TEST_FILES_DIR/test.png"
    log_info "Generating test asset..."
    if ! generate_png_file "$test_file"; then
        log_error "Failed to generate test PNG file"
        exit 1
    fi
    
    # Add the test asset to the database
    log_info "Adding test asset to database..."
    local add_output
    add_output=$($(get_cli_command) add --db "$TEST_DB_DIR" "$test_file" --verbose --yes --session-id "setup-process" 2>&1)
    
    if [ $? -ne 0 ]; then
        log_error "Failed to add test asset to database"
        echo "$add_output"
        exit 1
    fi
    
    # Extract asset ID from output (declare as global)
    ASSET_ID=$(echo "$add_output" | grep "Added file.*with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1)
    
    if [ -z "$ASSET_ID" ]; then
        log_error "Failed to extract asset ID from add output"
        echo "Add output:"
        echo "$add_output"
        exit 1
    fi
    
    log_info "Test asset added with ID: $ASSET_ID"
    
    log_success "Test environment setup complete"
}

# Create replica databases
create_replicas() {
    log_info "Creating $NUM_REPLICAS replica databases..."
    
    # Create array to store database paths (declare as global)
    DB_PATHS=("$TEST_DB_DIR")
    
    # Create replica databases
    for ((i=1; i<NUM_REPLICAS; i++)); do
        local replica_dir="$TEST_DB_DIR-replica-$i"
        DB_PATHS+=("$replica_dir")
        
        log_info "Creating replica $i: $replica_dir"
        rm -rf "$replica_dir"
        
        # Replicate the original database
        $(get_cli_command) replicate --db "$TEST_DB_DIR" --dest "$replica_dir" --yes --force > /dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            log_error "Failed to create replica $i"
            exit 1
        fi
    done
    
    log_success "Created $NUM_REPLICAS databases (1 original + $((NUM_REPLICAS-1)) replicas)"
}

# Worker process function
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
        hash_before=$($(get_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
        
        if [ -z "$hash_before" ]; then
            log_error "Process $process_id, iteration $i: Failed to get root hash before edit"
            echo "$i,$edit_uuid,,,HASH_BEFORE_FAILED," >> "$output_file"
            continue
        fi
        
        # Edit the description field using bdb-cli
        # Note: bdb command path format matches existing smoke tests
        local edit_output
        edit_output=$($(get_bdb_command) edit "$db_path/metadata" metadata "$ASSET_ID" description string "$edit_uuid" 2>&1)
        local edit_exit_code=$?
        
        if [ $edit_exit_code -ne 0 ]; then
            log_error "Process $process_id, iteration $i: Failed to edit description"
            echo "$edit_output" >> "$output_file"
            echo "$i,$edit_uuid,$hash_before,,EDIT_FAILED," >> "$output_file"
            continue
        fi
        
        # Get root hash after edit
        local hash_after
        hash_after=$($(get_cli_command) root-hash --db "$db_path" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
        
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
                sync_output=$($(get_cli_command) sync --db "$db_path" --dest "$other_db" --yes 2>&1)
                local sync_exit_code=$?
                
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

# Final round of syncing
final_sync_round() {
    log_info "Performing final round of syncing between all databases..."
    
    # Sync each database with every other database
    for ((i=0; i<NUM_REPLICAS; i++)); do
        for ((j=0; j<NUM_REPLICAS; j++)); do
            if [ $i -ne $j ]; then
                local source_db="${DB_PATHS[$i]}"
                local dest_db="${DB_PATHS[$j]}"
                log_info "Syncing database $i -> $j"
                
                $(get_cli_command) sync --db "$source_db" --dest "$dest_db" --yes > /dev/null 2>&1
                
                if [ $? -ne 0 ]; then
                    log_error "Failed to sync database $i -> $j"
                    return 1
                fi
            fi
        done
    done
    
    log_success "Final sync round completed"
}

# Verify root hashes match
verify_root_hashes() {
    log_info "Verifying all databases have the same root hash..."
    
    local original_hash
    original_hash=$($(get_cli_command) root-hash --db "${DB_PATHS[0]}" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ -z "$original_hash" ]; then
        log_error "Failed to get root hash from original database"
        return 1
    fi
    
    log_info "Original database root hash: $original_hash"
    
    # Check each replica
    for ((i=1; i<NUM_REPLICAS; i++)); do
        local replica_hash
        replica_hash=$($(get_cli_command) root-hash --db "${DB_PATHS[$i]}" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
        
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

# Main test execution
main() {
    echo "============================================================================"
    echo "=== PHOTOSPHERE SYNC SMOKE TEST ==="
    echo "============================================================================"
    echo "Configuration:"
    echo "  Total databases: $NUM_REPLICAS"
    echo "  Iterations per process: $NUM_ITERATIONS"
    echo "  Use binary: $USE_BINARY"
    echo "  CLI command: $(get_cli_command)"
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
        log_error "Parallel processes failed"
        exit 1
    fi
    
    # Clear background_pids since all processes completed successfully
    background_pids=()
    
    # Final round of syncing
    if ! final_sync_round; then
        log_error "Final sync round failed"
        exit 1
    fi
    
    # Verify root hashes
    if ! verify_root_hashes; then
        log_error "Root hash verification failed"
        exit 1
    fi
    
    log_success "Sync smoke test PASSED"
    log_info "Test data preserved in: $TEST_DB_DIR, $TEST_FILES_DIR, $PROCESS_OUTPUT_DIR"
    log_info "Process logs: $PROCESS_OUTPUT_DIR/process_*.log"
    
    exit 0
}

# Run main function
main "$@"

