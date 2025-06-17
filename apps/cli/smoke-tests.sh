#!/bin/bash

# Photosphere CLI Smoke Tests
# Based on test plan from photosphere-wiki/Test-plan-from-repo.md
# This script runs smoke tests to verify basic CLI functionality

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DB_DIR="./test/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-images"

# Debug mode flag (can be set via environment variable or command line)
DEBUG_MODE=${DEBUG_MODE:-false}

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

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$1")
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if a value matches expected value
expect_value() {
    local actual="$1"
    local expected="$2"
    local description="$3"
    
    if [ "$actual" = "$expected" ]; then
        log_success "$description: $actual"
        return 0
    else
        log_error "$description: expected $expected, got $actual"
        exit 1
    fi
}

# Parse a value from output and check if it matches expected value
expect_output_value() {
    local output="$1"
    local pattern="$2"
    local expected="$3"
    local description="$4"
    
    local actual=$(parse_numeric "$output" "$pattern")
    expect_value "$actual" "$expected" "$description"
}

# Parse a numeric value from output based on a pattern
parse_numeric() {
    local output="$1"
    local pattern="$2"
    local default_value="${3:-0}"
    
    # First strip ANSI color codes if present
    local clean_output=$(echo "$output" | sed $'s/\033\[[0-9;]*m//g')
    
    # Escape special regex characters in the pattern
    local escaped_pattern=$(echo "$pattern" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Try to extract numeric value in different positions relative to pattern
    local value=""
    
    # First try: number follows pattern (e.g., "Total files: 15")
    value=$(echo "$clean_output" | sed -n "s/.*${escaped_pattern}[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1)
    
    # If not found, try: number precedes pattern (e.g., "15 files added")
    if [ -z "$value" ]; then
        value=$(echo "$clean_output" | sed -n "s/.*\([0-9][0-9]*\)[[:space:]]*${escaped_pattern}.*/\1/p" | head -1)
    fi
    
    # Return the value or default if not found
    echo "${value:-$default_value}"
}


# Run a command and check its exit code
run_command() {
    local description="$1"
    local command="$2"
    local expected_exit_code="${3:-0}"
    
    log_info "Running: $description"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$command${NC}"
    echo ""
    
    # For macOS, check if binary exists and is executable
    if [[ "$OSTYPE" == "darwin"* ]] && [[ "$command" == *"psi"* ]]; then
        local binary_path=$(echo "$command" | awk '{print $1}')
        if [ -f "$binary_path" ]; then
            log_info "Binary exists at: $binary_path"
            file "$binary_path" || true
            log_info "Binary permissions: $(ls -la "$binary_path")"
        fi
    fi
    
    if eval "$command"; then
        if [ $expected_exit_code -eq 0 ]; then
            log_success "$description"
            return 0
        else
            log_error "$description (expected failure but command succeeded)"
            exit 1  # Exit immediately on failure
        fi
    else
        local actual_exit_code=$?
        if [ $expected_exit_code -ne 0 ]; then
            log_success "$description (expected failure with exit code $actual_exit_code)"
            return 0
        else
            log_error "$description (exit code: $actual_exit_code)"
            # Special handling for macOS illegal instruction error
            if [ $actual_exit_code -eq 132 ] && [[ "$OSTYPE" == "darwin"* ]]; then
                log_error "Illegal instruction error on macOS - binary may be compiled for wrong architecture"
            fi
            exit 1  # Exit immediately on failure
        fi
    fi
}

# Check if a directory/file exists
check_exists() {
    local path="$1"
    local description="$2"
    
    if [ -e "$path" ]; then
        log_success "$description exists: $path"
        return 0
    else
        log_error "$description missing: $path"
        exit 1  # Exit immediately on failure
    fi
}

# Check if a directory is empty
check_empty() {
    local path="$1"
    local description="$2"
    
    if [ -z "$(ls -A "$path" 2>/dev/null)" ]; then
        log_success "$description is empty: $path"
        return 0
    else
        log_error "$description is not empty: $path"
        exit 1  # Exit immediately on failure
    fi
}

# Count files in summary output
count_files_in_summary() {
    local summary_output="$1"
    # Extract number from summary output like "1 files in database"
    echo "$summary_output" | grep -o '[0-9]\+ files' | grep -o '[0-9]\+' | head -1
}

# Detect platform and set build command
detect_platform() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "mac";;
        CYGWIN*|MINGW*|MSYS*) echo "win";;
        *)          echo "linux";;  # Default to linux
    esac
}

# Detect architecture
detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64)    echo "x64";;
        arm64|aarch64)   echo "arm64";;
        *)               echo "x64";;  # Default to x64
    esac
}

# Individual test functions
test_setup() {
    local platform=$(detect_platform)
    local arch=$(detect_architecture)
    log_info "Detected platform: $platform"
    log_info "Detected architecture: $arch"
    
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi
    
    local cli_command=$(get_cli_command)
    log_info "Using CLI command: $cli_command"
    
    log_info "Cleaning up previous test run"
    rm -rf "$TEST_DB_DIR"
    
    log_info "Building CLI executable for platform: $platform ($arch)"
    case "$platform" in
        "linux")
            run_command "Build Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                run_command "Build macOS ARM64 executable" "bun run build-mac-arm64"
            else
                run_command "Build macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            run_command "Build Windows executable" "bun run build-win"
            ;;
    esac
    
    log_info "Building frontend for platform: $platform"
    run_command "Build frontend" "bun run build-fe-$platform" || {
        log_warning "Frontend build failed, continuing anyway..."
    }
    
}

test_install_tools() {
    echo ""
    echo "=== CHECK TOOLS ==="
    
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi
    
    local cli_command=$(get_cli_command)
    log_info "Using CLI command: $cli_command"
    
    log_info "Checking for required tools in system PATH"
    run_command "Check tools" "$(get_cli_command) tools --yes"
    echo ""
    
    log_info "Verifying tools are installed and working..."
    
    # Check that required tools exist and can print versions
    local tools_verified=true
    
    # Check ImageMagick
    if command -v magick &> /dev/null; then
        local magick_output=$(magick --version || echo "")
        if [ -n "$magick_output" ]; then
            log_success "ImageMagick verified - complete output:"
            echo "$magick_output"
        else
            log_error "ImageMagick command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ImageMagick not found in system PATH"
        tools_verified=false
    fi
    
    # Check ffprobe
    if command -v ffprobe &> /dev/null; then
        local ffprobe_version=$(ffprobe -version | head -1 | sed 's/ffprobe version //' | cut -d' ' -f1 || echo "")
        if [ -n "$ffprobe_version" ]; then
            log_success "ffprobe verified: version $ffprobe_version"
        else
            log_error "ffprobe command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ffprobe not found in system PATH"
        tools_verified=false
    fi
    
    # Check ffmpeg
    if command -v ffmpeg &> /dev/null; then
        local ffmpeg_version=$(ffmpeg -version | head -1 | sed 's/ffmpeg version //' | cut -d' ' -f1 || echo "")
        if [ -n "$ffmpeg_version" ]; then
            log_success "ffmpeg verified: version $ffmpeg_version"
        else
            log_error "ffmpeg command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ffmpeg not found in system PATH"
        tools_verified=false
    fi
    
    # Fail the tests if any tools are not working
    if [ "$tools_verified" = false ]; then
        log_error "Tool verification failed - some required tools are missing or not working"
        exit 1
    fi
    
    log_success "All tools verified and working correctly"
}

test_create_database() {
    echo ""
    echo "=== TEST 1: CREATE DATABASE ==="
    
    run_command "Initialize new database" "$(get_cli_command) init $TEST_DB_DIR --yes"
    
    # Check if required files were created
    check_exists "$TEST_DB_DIR" "Database directory"
    check_exists "$TEST_DB_DIR/.db" "Database metadata directory"
    check_exists "$TEST_DB_DIR/.db/tree.dat" "Database tree file"
    check_exists "$TEST_DB_DIR/metadata" "Asset metadata directory"
    
    # Test initial state - database creation is verified by file existence checks above
}

test_view_media_files() {
    echo ""
    echo "=== TEST 2: VIEW LOCAL MEDIA FILES ==="
    
    run_command "Show info for test files" "$(get_cli_command) info $TEST_FILES_DIR/ --yes"
}

# Parameterized function to test adding a single file
test_add_file_parameterized() {
    local file_path="$1"
    local file_type="$2"
    local test_description="$3"
    
    # Check if file exists
    if [ ! -f "$file_path" ]; then
        log_warning "$file_type test file not found: $file_path"
        log_warning "Skipping $file_type file test"
        return
    fi
    
    # Get initial database state - count files in metadata collection
    # Use the info command output to track actual media files added
    local before_check=$($(get_cli_command) check $TEST_DB_DIR $file_path --yes 2>&1)
    local already_in_db=$(parse_numeric "$before_check" "files already in database")
    
    # Add the file
    local add_output
    add_output=$($(get_cli_command) add $TEST_DB_DIR $file_path --yes 2>&1)
    echo "$add_output"
    
    # Check if command succeeded
    if [ $? -ne 0 ]; then
        log_error "$test_description failed"
        exit 1
    fi
    
    # Extract from the add command summary how many files were actually added
    local files_added=$(parse_numeric "$add_output" "files added")
    local files_failed=$(parse_numeric "$add_output" "files failed")
    local files_already=$(parse_numeric "$add_output" "files already in the database")
    
    # Verify exactly one file was added (or was already there)
    if [ "$already_in_db" -eq "1" ]; then
        # File was already in database
        expect_value "$files_already" "1" "$file_type file already in database"
        expect_value "$files_added" "0" "$file_type file added (should be 0 since already exists)"
    else
        # File should be newly added
        expect_value "$files_added" "1" "$file_type file added"
        expect_value "$files_failed" "0" "$file_type file failed"
    fi
    
    # Check that the specific file is now in the database
    run_command "Check $file_type file added" "$(get_cli_command) check $TEST_DB_DIR $file_path --yes"
}

test_add_png_file() {
    echo ""
    echo "=== TEST 3: ADD PNG FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.png" "PNG" "Add PNG file"
}

test_add_jpg_file() {
    echo ""
    echo "=== TEST 4: ADD JPG FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.jpg" "JPG" "Add JPG file"
}

test_add_mp4_file() {
    echo ""
    echo "=== TEST 5: ADD MP4 FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.mp4" "MP4" "Add MP4 file"
}

test_add_same_file() {
    echo ""
    echo "=== TEST 6: ADD SAME FILE (NO DUPLICATION) ==="
    
    # Try to re-add the PNG file (should not add it again)
    run_command "Re-add same file" "$(get_cli_command) add $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    
    run_command "Check file still in database" "$(get_cli_command) check $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
}

test_add_multiple_files() {
    echo ""
    echo "=== TEST 7: ADD MULTIPLE FILES ==="
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        run_command "Add multiple files" "$(get_cli_command) add $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
        
        run_command "Check multiple files added" "$(get_cli_command) check $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
}

test_add_same_multiple_files() {
    echo ""
    echo "=== TEST 8: ADD SAME MULTIPLE FILES (NO DUPLICATION) ==="
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        run_command "Re-add multiple files" "$(get_cli_command) add $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
        
        run_command "Check multiple files still in database" "$(get_cli_command) check $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
}

test_database_summary() {
    echo ""
    echo "=== TEST 9: DATABASE SUMMARY ==="
    
    run_command "Display database summary" "$(get_cli_command) summary $TEST_DB_DIR --yes"
    
    # Capture summary output to verify it contains expected fields
    log_info "Running: Verify summary output format"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$(get_cli_command) summary $TEST_DB_DIR --yes${NC}"
    echo ""
    
    local summary_output
    summary_output=$($(get_cli_command) summary $TEST_DB_DIR --yes 2>&1)
    
    # Check that summary contains expected fields
    if echo "$summary_output" | grep -q "Total files:"; then
        log_success "Summary contains total files count"
    else
        log_error "Summary missing total files count"
        exit 1
    fi
    
    if echo "$summary_output" | grep -q "Total nodes:"; then
        log_success "Summary contains total nodes count"
    else
        log_error "Summary missing total nodes count"
        exit 1
    fi
    
    if echo "$summary_output" | grep -q "Total size:"; then
        log_success "Summary contains total size"
    else
        log_error "Summary missing total size"
        exit 1
    fi
    
    if echo "$summary_output" | grep -q "Tree root hash (short):"; then
        log_success "Summary contains short hash"
    else
        log_error "Summary missing short hash"
        exit 1
    fi
    
    if echo "$summary_output" | grep -q "Tree root hash (full):"; then
        log_success "Summary contains full hash"
    else
        log_error "Summary missing full hash"
        exit 1
    fi
}

test_database_verify() {
    echo ""
    echo "=== TEST 10: DATABASE VERIFICATION ==="
    
    run_command "Verify database integrity" "$(get_cli_command) verify $TEST_DB_DIR --yes"
    
    # Capture verify output to check results
    log_info "Running: Check verification output"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$(get_cli_command) verify $TEST_DB_DIR --yes${NC}"
    echo ""
    
    local verify_output
    verify_output=$($(get_cli_command) verify $TEST_DB_DIR --yes 2>&1)
    
    # Check that verification contains expected fields
    if echo "$verify_output" | grep -q "Total files:"; then
        log_success "Verify output contains total files count"
    else
        log_error "Verify output missing total files count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Total nodes:"; then
        log_success "Verify output contains total nodes count"
    else
        log_error "Verify output missing total nodes count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Unmodified:"; then
        log_success "Verify output contains unmodified count"
    else
        log_error "Verify output missing unmodified count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Modified:"; then
        log_success "Verify output contains modified count"
    else
        log_error "Verify output missing modified count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "New:"; then
        log_success "Verify output contains new count"
    else
        log_error "Verify output missing new count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Removed:"; then
        log_success "Verify output contains removed count"
    else
        log_error "Verify output missing removed count"
        exit 1
    fi
    
    # Check that the database is in a good state (no new, modified, or removed files)
    expect_output_value "$verify_output" "New:" "0" "New files in verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in verification"
}

test_database_verify_full() {
    echo ""
    echo "=== TEST 11: DATABASE VERIFICATION (FULL MODE) ==="
    
    # Test full verification mode
    run_command "Verify database (full mode)" "$(get_cli_command) verify $TEST_DB_DIR --full --yes"
    
    # Capture verify output to check results
    log_info "Running: Check full verification output"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$(get_cli_command) verify $TEST_DB_DIR --full --yes${NC}"
    echo ""
    
    local verify_output
    verify_output=$($(get_cli_command) verify $TEST_DB_DIR --full --yes 2>&1)
    
    # Check that verification contains expected fields
    if echo "$verify_output" | grep -q "Total files:"; then
        log_success "Full verify output contains total files count"
    else
        log_error "Full verify output missing total files count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Total nodes:"; then
        log_success "Full verify output contains total nodes count"
    else
        log_error "Full verify output missing total nodes count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Unmodified:"; then
        log_success "Full verify output contains unmodified count"
    else
        log_error "Full verify output missing unmodified count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Modified:"; then
        log_success "Full verify output contains modified count"
    else
        log_error "Full verify output missing modified count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "New:"; then
        log_success "Full verify output contains new count"
    else
        log_error "Full verify output missing new count"
        exit 1
    fi
    
    if echo "$verify_output" | grep -q "Removed:"; then
        log_success "Full verify output contains removed count"
    else
        log_error "Full verify output missing removed count"
        exit 1
    fi
    
    # Check that the database is in a good state even with full verification
    expect_output_value "$verify_output" "New:" "0" "New files in full verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in full verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in full verification"
}

test_database_replicate() {
    echo ""
    echo "=== TEST 12: DATABASE REPLICATION ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Clean up any existing replica
    if [ -d "$replica_dir" ]; then
        log_info "Cleaning up existing replica directory"
        rm -rf "$replica_dir"
    fi
    
    # Run replicate command
    log_info "Running: Replicate database"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$(get_cli_command) replicate $TEST_DB_DIR $replica_dir --yes${NC}"
    echo ""
    
    # Capture replication output to verify counts
    local replicate_output
    replicate_output=$($(get_cli_command) replicate $TEST_DB_DIR $replica_dir --yes 2>&1)
    
    # Display the command output
    echo "$replicate_output"
    
    # Check if replication was successful
    if echo "$replicate_output" | grep -q "Replication completed successfully"; then
        log_success "Replicate database"
    else
        log_error "Database replication failed"
        exit 1
    fi
    
    # Check expected values from replication output
    expect_output_value "$replicate_output" "Total files:" "15" "Total files reported"
    expect_output_value "$replicate_output" "Copied:" "15" "Files copied"
    expect_output_value "$replicate_output" "Skipped (unchanged):" "0" "Files skipped (first run)"
    
    # Check that replica was created
    check_exists "$replica_dir" "Replica database directory"
    check_exists "$replica_dir/.db" "Replica metadata directory"
    check_exists "$replica_dir/.db/tree.dat" "Replica tree file"
}

test_verify_replica() {
    echo ""
    echo "=== TEST 13: VERIFY REPLICA ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous test
    if [ ! -d "$replica_dir" ]; then
        log_error "Replica directory not found from previous test"
        exit 1
    fi
    
    # Verify replica contents match source
    run_command "Verify replica integrity" "$(get_cli_command) verify $replica_dir --yes"
    
    # Compare file counts between source and replica
    log_info "Running: Compare source and replica file counts"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "${BLUE}$(get_cli_command) summary $TEST_DB_DIR --yes${NC}"
    echo -e "${BLUE}$(get_cli_command) summary $replica_dir --yes${NC}"
    echo ""
    
    local source_summary
    source_summary=$($(get_cli_command) summary $TEST_DB_DIR --yes 2>&1)
    local replica_summary
    replica_summary=$($(get_cli_command) summary $replica_dir --yes 2>&1)
    
    local source_files=$(parse_numeric "$source_summary" "Total files:")
    local replica_files=$(parse_numeric "$replica_summary" "Total files:")
    
    expect_value "$replica_files" "$source_files" "Replica file count matches source"
}

test_database_replicate_second() {
    echo ""
    echo "=== TEST 14: SECOND DATABASE REPLICATION - NO CHANGES ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous test
    if [ ! -d "$replica_dir" ]; then
        log_error "Replica directory not found from previous test"
        exit 1
    fi
    
    # Run second replicate command
    log_info "Running: Second replication (no changes)"
    echo ""
    echo -e "${YELLOW}Command:${NC}"
    echo -e "${BLUE}$(get_cli_command) replicate $TEST_DB_DIR $replica_dir --yes${NC}"
    echo ""
    
    # Capture second replication output
    local second_replication_output
    second_replication_output=$($(get_cli_command) replicate $TEST_DB_DIR $replica_dir --yes 2>&1)
    
    # Display the command output
    echo "$second_replication_output"
    
    # Check if replication was successful
    if echo "$second_replication_output" | grep -q "Replication completed successfully"; then
        log_success "Second replication (no changes)"
    else
        log_error "Second database replication failed"
        exit 1
    fi
    
    # Check expected values from second replication output
    expect_output_value "$second_replication_output" "Total files:" "15" "Total files reported (second run)"
    expect_output_value "$second_replication_output" "Copied:" "0" "Files copied (all up to date)"
    expect_output_value "$second_replication_output" "Skipped (unchanged):" "15" "Files skipped (already exist)"   
}

test_database_compare() {
    echo ""
    echo "=== TEST 15: DATABASE COMPARISON ==="
    echo ""
    log_warning "Database comparison test temporarily disabled - depends on replicate command"
    log_warning "Skipping test 14: DATABASE COMPARISON"
    return
    
    # COMMENTED OUT UNTIL REPLICATE COMMAND IS FIXED
    # local replica_dir="$TEST_DB_DIR-replica"
    # 
    # # Create a replica for comparison testing
    # if [ -d "$replica_dir" ]; then
    #     log_info "Cleaning up existing replica directory"
    #     rm -rf "$replica_dir"
    # fi
    # 
    # run_command "Create replica for comparison" "$(get_cli_command) replicate $TEST_DB_DIR $replica_dir --yes"
    # 
    # # Test comparison between identical databases (should show no differences)
    # run_command "Compare identical databases" "$(get_cli_command) compare $TEST_DB_DIR $replica_dir --yes"
    # 
    # # Capture compare output to verify results
    # local compare_output
    # compare_output=$($(get_cli_command) compare $TEST_DB_DIR $replica_dir --yes 2>&1)
    # 
    # # Check that comparison shows no differences for identical databases
    # if echo "$compare_output" | grep -q "No differences detected\|Databases are identical"; then
    #     log_success "Compare correctly identified identical databases"
    # else
    #     log_error "Compare failed to identify identical databases"
    #     echo "Compare output: $compare_output"
    #     exit 1
    # fi
    # 
    # # Test compare with output file
    # local compare_json="./compare-test-results.json"
    # run_command "Compare with JSON output" "$(get_cli_command) compare $TEST_DB_DIR $replica_dir --output $compare_json --yes"
    # 
    # # Check that JSON file was created
    # if [ -f "$compare_json" ]; then
    #     log_success "Compare JSON output file created"
    #     
    #     # Check JSON content contains expected fields
    #     if grep -q '"treesMatch"' "$compare_json" && grep -q '"differences"' "$compare_json"; then
    #         log_success "Compare JSON contains expected structure"
    #     else
    #         log_error "Compare JSON missing expected fields"
    #         exit 1
    #     fi
    #     
    #     # Clean up JSON file
    #     rm -f "$compare_json"
    # else
    #     log_error "Compare JSON output file not created"
    #     exit 1
    # fi
    # 
    # # Test comparison with self (database vs itself)
    # run_command "Compare database with itself" "$(get_cli_command) compare $TEST_DB_DIR $TEST_DB_DIR --yes"
    # 
    # # Clean up replica
    # log_info "Cleaning up replica directory"
    # rm -rf "$replica_dir"
}

test_cannot_create_over_existing() {
    echo ""
    echo "=== TEST 16: CANNOT CREATE DATABASE OVER EXISTING ==="
    
    run_command "Fail to create database over existing" "$(get_cli_command) init $TEST_DB_DIR --yes" 1
}


# Reset function to clean up test artifacts
reset_environment() {
    echo "======================================"
    echo "Photosphere CLI Smoke Tests - RESET"
    echo "======================================"
    
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi
    
    log_info "Current directory: $(pwd)"
    log_info "Cleaning up test artifacts..."
    
    # Remove the specific test database directory
    if [ -d "$TEST_DB_DIR" ]; then
        log_info "Removing test database: $TEST_DB_DIR"
        rm -rf "$TEST_DB_DIR"
        log_success "Removed $TEST_DB_DIR"
    else
        log_info "Test database directory not found (already clean): $TEST_DB_DIR"
    fi
    
    # Remove the replicated database directory
    local replica_dir="$TEST_DB_DIR-replica"
    if [ -d "$replica_dir" ]; then
        log_info "Removing replicated database: $replica_dir"
        rm -rf "$replica_dir"
        log_success "Removed $replica_dir"
    else
        log_info "Replicated database directory not found (already clean): $replica_dir"
    fi
    
    log_success "Environment reset complete!"
    echo ""
    log_info "You can now run tests with a clean environment:"
    log_info "  $0 all              # Run all tests"
    log_info "  $0 setup            # Run just setup"
    log_info "  $0 create-database  # Run specific test"
}

# Function to run all tests
run_all_tests() {
    echo "======================================"
    echo "Photosphere CLI Smoke Tests - ALL"
    echo "======================================"
    
    log_info "Running all tests (assumes executable is already built and tools are available)"
    log_info "To build and run all tests with tool installation, use: ./smoke-tests.sh setup,install-tools,all"
    echo ""
    
    # Change to CLI directory for tests
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        exit 1
    fi
    
    # Clean up previous test run
    log_info "Resetting testing environment"
    if [ -d "$TEST_DB_DIR" ]; then
        rm -rf "$TEST_DB_DIR"
        log_success "Removed existing test database"
    else
        log_info "Test database directory not found (already clean)"
    fi
    
    # Run all tests in sequence 
    test_create_database
    test_view_media_files
    test_add_png_file
    test_add_jpg_file
    test_add_mp4_file
    test_add_same_file
    test_add_multiple_files
    test_add_same_multiple_files
    test_database_summary
    test_database_verify
    test_database_verify_full
    test_database_replicate
    test_verify_replica
    test_database_replicate_second
    test_database_compare
    test_cannot_create_over_existing
    
    # If we get here, all tests passed
    echo ""
    echo "======================================"
    echo "TEST SUMMARY"
    echo "======================================"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}ALL SMOKE TESTS PASSED${NC}"
    
    # Cleanup after all tests complete
    echo ""
    log_info "Cleaning up test artifacts..."
    if [ -d "$TEST_DB_DIR" ]; then
        rm -rf "$TEST_DB_DIR"
        log_info "Removed test database"
    fi
    exit 0
}

# Function to run a specific test
run_test() {
    local test_name="$1"
    
    case "$test_name" in
        "all")
            run_all_tests
            ;;
        "reset")
            reset_environment
            ;;
        "setup")
            # This is handled as a command in main(), but keeping here for completeness
            test_setup
            ;;
        "install-tools")
            test_install_tools
            ;;
        "create-database"|"1")
            test_create_database
            ;;
        "view-media"|"2")
            test_view_media_files
            ;;
        "add-png"|"3")
            test_add_png_file
            ;;
        "add-jpg"|"4")
            test_add_jpg_file
            ;;
        "add-mp4"|"5")
            test_add_mp4_file
            ;;
        "add-same"|"6")
            test_add_same_file
            ;;
        "add-multiple"|"7")
            test_add_multiple_files
            ;;
        "add-same-multiple"|"8")
            test_add_same_multiple_files
            ;;
        "summary"|"9")
            test_database_summary
            ;;
        "verify"|"10")
            test_database_verify
            ;;
        "verify-full"|"11")
            test_database_verify_full
            ;;
        "replicate"|"12")
            test_database_replicate
            ;;
        "verify-replica"|"13")
            test_verify_replica
            ;;
        "replicate-second"|"14")
            test_database_replicate_second
            ;;
        "compare"|"15")
            test_database_compare
            ;;
        "no-overwrite"|"16")
            test_cannot_create_over_existing
            ;;
        *)
            log_error "Unknown test: $test_name"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Function to run multiple commands in sequence
run_multiple_commands() {
    local commands_string="$1"
    
    # Split commands by comma
    IFS=',' read -ra COMMANDS <<< "$commands_string"
    
    echo "======================================"
    echo "Photosphere CLI Smoke Tests - MULTIPLE"
    echo "======================================"
    log_info "Running ${#COMMANDS[@]} commands in sequence: $commands_string"
    echo ""
    
    local command_number=1
    local total_commands=${#COMMANDS[@]}
    
    for command in "${COMMANDS[@]}"; do
        # Trim whitespace
        command=$(echo "$command" | xargs)
        
        echo ""
        echo "--- Command $command_number/$total_commands: $command ---"
        
        # Execute command with error handling
        # Keep set -e enabled to fail immediately
        case "$command" in
            "all")
                # Run all tests within the multiple command sequence
                # Each test will exit immediately on failure due to set -e
                test_create_database
                test_view_media_files
                test_add_png_file
                test_add_jpg_file
                test_add_mp4_file
                test_add_same_file
                test_add_multiple_files
                test_add_same_multiple_files
                test_database_summary
                test_database_verify
                test_database_verify_full
                test_database_replicate
                test_verify_replica
                test_database_replicate_second
                test_database_compare
                test_cannot_create_over_existing
                ;;
            "setup")
                test_setup
                ;;
            "install-tools")
                test_install_tools
                ;;
            "reset")
                reset_environment
                ;;
            "create-database"|"1")
                test_create_database
                ;;
            "view-media"|"2")
                test_view_media_files
                ;;
            "add-png"|"3")
                test_add_png_file
                ;;
            "add-jpg"|"4")
                test_add_jpg_file
                ;;
            "add-mp4"|"5")
                test_add_mp4_file
                ;;
            "add-same"|"6")
                test_add_same_file
                ;;
            "add-multiple"|"7")
                test_add_multiple_files
                ;;
            "add-same-multiple"|"8")
                test_add_same_multiple_files
                ;;
            "summary"|"9")
                test_database_summary
                ;;
            "verify"|"10")
                test_database_verify
                ;;
            "verify-full"|"11")
                test_database_verify_full
                ;;
            "replicate"|"12")
                test_database_replicate
                ;;
            "verify-replica"|"13")
                test_verify_replica
                ;;
            "replicate-second"|"14")
                test_database_replicate_second
                ;;
            "compare"|"15")
                test_database_compare
                ;;
            "no-overwrite"|"16")
                test_cannot_create_over_existing
                ;;
            *)
                log_error "Unknown command in sequence: $command"
                echo ""
                show_usage
                set -e
                exit 1
                ;;
        esac
        
        # If we get here, the command succeeded (otherwise it would have exited)
        log_success "Completed command $command_number/$total_commands: $command"
        command_number=$((command_number + 1))
    done
    
    # Show final summary - we only get here if all commands succeeded
    echo ""
    echo "======================================"
    echo "MULTIPLE COMMANDS SUMMARY"
    echo "======================================"
    echo -e "Commands run: ${BLUE}$total_commands${NC}"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}ALL COMMANDS COMPLETED SUCCESSFULLY${NC}"
    
    # Check if database should be preserved
    if [ "${PRESERVE_DATABASE:-false}" = "true" ]; then
        echo ""
        log_info "Database preserved for inspection at: $TEST_DB_DIR"
        log_info "To clean up when done: $0 reset"
    fi
    
    exit 0
}

# Show usage information
show_usage() {
    echo "Usage: $0 [options] <command|test-name> [command2,command3,...]"
    echo "       $0 [options] to <test-number>"
    echo ""
    echo "Run Photosphere CLI smoke tests"
    echo ""
    echo "Options:"
    echo "  -d, --debug         - Run tests using 'bun run start --' instead of built executable"
    echo "  -h, --help          - Show this help message"
    echo ""
    echo "Commands:"
    echo "  all                 - Run all tests (assumes executable built and tools available)"
    echo "  to <number>         - Run tests 1 through <number> (preserves database for inspection)"
    echo "  setup               - Build executable and frontend"
    echo "  install-tools       - Install required media processing tools only"
    echo "  reset               - Clean up test artifacts and reset environment"
    echo "  help                - Show this help message"
    echo ""
    echo "Individual tests:"
    echo "  create-database (1) - Create new database"
    echo "  view-media (2)      - View local media files"
    echo "  add-png (3)         - Add PNG file to database"
    echo "  add-jpg (4)         - Add JPG file to database"
    echo "  add-mp4 (5)         - Add MP4 file to database"
    echo "  add-same (6)        - Add same file again (no duplication)"
    echo "  add-multiple (7)    - Add multiple files"
    echo "  add-same-multiple (8) - Add same multiple files again"
    echo "  summary (9)         - Display database summary"
    echo "  verify (10)         - Verify database integrity"
    echo "  verify-full (11)    - Verify database integrity (full mode)"
    echo "  replicate (12)      - Replicate database to new location"
    echo "  verify-replica (13) - Verify replica integrity and match with source"
    echo "  replicate-second (14) - Second replication (no changes)"
    echo "  compare (15)        - Compare two databases (DISABLED)"
    echo "  no-overwrite (16)   - Cannot create database over existing"
    echo ""
    echo "Multiple commands:"
    echo "  Use commas to separate commands (no spaces around commas)"
    echo ""
    echo "Examples:"
    echo "  $0 all                      # Run all tests (exe must be built, tools available)"
    echo "  $0 --debug all              # Run all tests using debug mode (bun run start --)"
    echo "  $0 to 5                     # Run tests 1-5 and keep database for inspection"
    echo "  $0 -d to 10                 # Run tests 1-10 in debug mode and keep database"
    echo "  $0 setup,all                # Build and run all tests (tools must be available)"
    echo "  $0 setup,install-tools,all  # Build, install tools, and run all tests"
    echo "  $0 setup                    # Build executable and frontend only"
    echo "  $0 install-tools            # Install tools only"
    echo "  $0 reset                    # Clean up test artifacts"
    echo "  $0 create-database          # Run only database creation test"
    echo "  $0 3                        # Run test 3 (add single file)"
    echo "  $0 reset,setup,1,3          # Reset, setup, create DB, then test 3"
    echo "  DEBUG_MODE=true $0 all      # Alternative way to enable debug mode"
    echo "  $0 help                     # Show this help"
}

# Main test execution
main() {
    # Parse command line options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--debug)
                DEBUG_MODE=true
                shift
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                break  # End of options, remaining arguments are commands
                ;;
        esac
    done
    
    # Check for help request or no arguments after parsing options
    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    # Show debug mode status if enabled
    if [ "$DEBUG_MODE" = "true" ]; then
        log_info "Debug mode enabled - using 'bun run start --' instead of built executable"
    fi
    
    # Check if "to" command is used (e.g., "./smoke-tests.sh to 5")
    if [ "$1" = "to" ] && [ $# -eq 2 ]; then
        local end_test="$2"
        # Validate that end_test is a number between 1 and 16
        if [[ "$end_test" =~ ^[0-9]+$ ]] && [ "$end_test" -ge 1 ] && [ "$end_test" -le 16 ]; then
            # Build command list from 1 to end_test
            local commands="1"
            for ((i=2; i<=end_test; i++)); do
                commands="$commands,$i"
            done
            log_info "Running tests 1 through $end_test"
            # Set flag to preserve database
            PRESERVE_DATABASE=true
            # Reset environment before running tests
            log_info "Resetting testing environment"
            if [ -d "$TEST_DB_DIR" ]; then
                rm -rf "$TEST_DB_DIR"
                log_success "Removed existing test database"
            else
                log_info "Test database directory not found (already clean)"
            fi
            run_multiple_commands "$commands"
            return
        else
            log_error "Invalid test number: $end_test (must be 1-16)"
            show_usage
            exit 1
        fi
    fi
    
    # Check if multiple commands are provided (contains comma)
    if [[ "$1" == *","* ]]; then
        run_multiple_commands "$1"
        return
    fi
    
    # Check if running all tests
    if [ "$1" = "all" ]; then
        run_all_tests
        return
    fi
    
    # Check if running reset command
    if [ "$1" = "reset" ]; then
        reset_environment
        exit 0
    fi
    
    # Check if running setup command
    if [ "$1" = "setup" ]; then
        test_setup
        exit 0
    fi
    
    # Check if running install-tools command
    if [ "$1" = "install-tools" ]; then
        test_install_tools
        exit 0
    fi
    
    # Running individual test
    echo "======================================"
    echo "Photosphere CLI Smoke Tests"
    echo "======================================"
    
    log_info "Running specific test: $1"
    
    # Set cleanup behavior based on test type
    case "$1" in
        "view-media"|"2")
            # view-media doesn't need or create a database, safe to cleanup
            ;;
        "create-database"|"1")
            # Don't cleanup after create-database - other tests might need it
            ;;
        *)
            # Other tests might depend on existing database, don't cleanup unless it's a standalone test
            ;;
    esac
    
    run_test "$1"
    
    # If we get here, test passed
    echo ""
    echo "======================================"
    echo "INDIVIDUAL TEST SUMMARY"
    echo "======================================"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}TEST PASSED${NC}"
    exit 0
}

# Run main function
main "$@"