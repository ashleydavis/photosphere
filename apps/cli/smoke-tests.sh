#!/bin/bash

# Photosphere CLI Smoke Tests
# Based on test plan from photosphere-wiki/Test-plan-from-repo.md
# This script runs smoke tests to verify basic CLI functionality

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
TEST_DB_DIR="./test/tmp/test-db"
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

# Global variable to store which ImageMagick command to use
IMAGEMAGICK_IDENTIFY_CMD=""

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

# Test counting functions - only increment once per test function
test_passed() {
    ((TESTS_PASSED++))
}

test_failed() {
    local test_name="$1"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$test_name")
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}


generate_test_report() {
    local report_file="$1"
    local test_mode="${2:-all}"
    
    log_info "Generating comprehensive test report: $report_file"
    
    # Create report header
    cat > "$report_file" << EOF
================================================================================
PHOTOSPHERE CLI SMOKE TEST REPORT
================================================================================
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Test Mode: $test_mode
Platform: $(detect_platform) $(detect_architecture)
Working Directory: $(pwd)
NODE_ENV: ${NODE_ENV:-'(not set)'}

================================================================================
TEST RESULTS SUMMARY
================================================================================
Tests Passed: $TESTS_PASSED
Tests Failed: $TESTS_FAILED
EOF

    # Add failed tests if any
    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo "" >> "$report_file"
        echo "Failed Tests:" >> "$report_file"
        for failed_test in "${FAILED_TESTS[@]}"; do
            echo "  - $failed_test" >> "$report_file"
        done
    fi

    # Add database information if database exists
    if [ -d "$TEST_DB_DIR" ] && [ -f "$TEST_DB_DIR/.db/tree.dat" ]; then
        echo "" >> "$report_file"
        echo "=================================================================================" >> "$report_file"
        echo "DATABASE INFORMATION" >> "$report_file"
        echo "=================================================================================" >> "$report_file"
        echo "Database Directory: $TEST_DB_DIR" >> "$report_file"
        echo "" >> "$report_file"
        
        # Get root hash
        echo "ROOT HASH:" >> "$report_file"
        echo "----------" >> "$report_file"
        $(get_cli_command) debug root-hash --db "$TEST_DB_DIR" --yes 2>/dev/null >> "$report_file" || echo "Failed to get root hash" >> "$report_file"
        echo "" >> "$report_file"
        
        # Get merkle tree
        echo "MERKLE TREE STRUCTURE:" >> "$report_file"
        echo "---------------------" >> "$report_file"
        $(get_cli_command) debug merkle-tree --db "$TEST_DB_DIR" --yes 2>/dev/null >> "$report_file" || echo "Failed to get merkle tree" >> "$report_file"
        echo "" >> "$report_file"
        
        # Get database summary
        echo "DATABASE SUMMARY:" >> "$report_file"
        echo "-----------------" >> "$report_file"
        $(get_cli_command) summary --db "$TEST_DB_DIR" --yes 2>/dev/null >> "$report_file" || echo "Failed to get database summary" >> "$report_file"
        echo "" >> "$report_file"
        
        # Get database file listing
        echo "DATABASE FILE LISTING:" >> "$report_file"
        echo "----------------------" >> "$report_file"
        $(get_cli_command) list --db "$TEST_DB_DIR" --page-size 50 --yes 2>/dev/null >> "$report_file" || echo "Failed to get database listing" >> "$report_file"
        echo "" >> "$report_file"
        
        # Get database verification
        echo "DATABASE VERIFICATION:" >> "$report_file"
        echo "----------------------" >> "$report_file"
        $(get_cli_command) verify --db "$TEST_DB_DIR" --yes 2>/dev/null >> "$report_file" || echo "Failed to verify database" >> "$report_file"
        echo "" >> "$report_file"
        
        # Show database directory structure
        echo "DATABASE DIRECTORY STRUCTURE:" >> "$report_file"
        echo "-----------------------------" >> "$report_file"
        if command -v tree &> /dev/null; then
            tree "$TEST_DB_DIR" 2>/dev/null >> "$report_file" || ls -la "$TEST_DB_DIR" >> "$report_file"
        else
            find "$TEST_DB_DIR" -type f | sort >> "$report_file" 2>/dev/null || echo "Failed to list database files" >> "$report_file"
        fi
        echo "" >> "$report_file"
    else
        echo "" >> "$report_file"
        echo "=================================================================================" >> "$report_file"
        echo "DATABASE INFORMATION" >> "$report_file"
        echo "=================================================================================" >> "$report_file"
        echo "No database found at: $TEST_DB_DIR" >> "$report_file"
        echo "" >> "$report_file"
    fi
    
    # Get hash cache information
    echo "=================================================================================" >> "$report_file"
    echo "HASH CACHE INFORMATION" >> "$report_file"
    echo "=================================================================================" >> "$report_file"
    
    # Get local and database hash cache info
    if [ -d "$TEST_DB_DIR" ]; then
        $(get_cli_command) debug hash-cache --db "$TEST_DB_DIR" --yes 2>/dev/null >> "$report_file" || echo "Failed to get hash cache information" >> "$report_file"
    else
        $(get_cli_command) debug hash-cache --yes 2>/dev/null >> "$report_file" || echo "Failed to get hash cache information" >> "$report_file"
    fi
    echo "" >> "$report_file"
    
    # Add system information
    echo "=================================================================================" >> "$report_file"
    echo "SYSTEM INFORMATION" >> "$report_file"
    echo "=================================================================================" >> "$report_file"
    echo "Operating System: $(uname -a)" >> "$report_file"
    echo "Current User: $(whoami)" >> "$report_file"
    echo "Current Directory: $(pwd)" >> "$report_file"
    echo "Disk Usage:" >> "$report_file"
    df -h . 2>/dev/null >> "$report_file" || echo "Failed to get disk usage" >> "$report_file"
    echo "" >> "$report_file"
    
    # Add CLI version information
    echo "CLI VERSION INFORMATION:" >> "$report_file"
    echo "------------------------" >> "$report_file"
    $(get_cli_command) version 2>/dev/null >> "$report_file" || echo "Failed to get CLI version" >> "$report_file"
    echo "" >> "$report_file"
    
    # Add tool information
    echo "TOOL INFORMATION:" >> "$report_file"
    echo "-----------------" >> "$report_file"
    $(get_cli_command) tools --yes 2>/dev/null >> "$report_file" || echo "Failed to get tool information" >> "$report_file"
    echo "" >> "$report_file"
    
    # Add report footer
    echo "=================================================================================" >> "$report_file"
    echo "END OF REPORT" >> "$report_file"
    echo "=================================================================================" >> "$report_file"
    echo "Report generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$report_file"
    
    log_success "Test report generated: $report_file"
    
    # Show report size
    if [ -f "$report_file" ]; then
        local file_size=$(stat -c%s "$report_file" 2>/dev/null || echo "unknown")
        log_info "Report size: $file_size bytes"
    fi
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

# Check if output contains expected string pattern
expect_output_string() {
    local output="$1"
    local pattern="$2"
    local description="$3"
    local should_contain="${4:-true}"
    
    if [ "$should_contain" = "true" ]; then
        if echo "$output" | grep -q "$pattern"; then
            log_success "$description"
            return 0
        else
            log_error "$description (pattern '$pattern' not found in output)"
            exit 1
        fi
    else
        if echo "$output" | grep -q "$pattern"; then
            log_error "$description (pattern '$pattern' should not be in output)"
            exit 1
        else
            log_success "$description"
            return 0
        fi
    fi
}

# Parse a numeric value from output based on a pattern
parse_numeric() {
    local output="$1"
    local pattern="$2"
    local default_value="${3:-0}"
    
    local clean_output="$output"
    
    # Escape special regex characters in the pattern - but keep parentheses as literals
    local escaped_pattern=$(echo "$pattern" | sed 's/[[\.*^$+?{|]/\\&/g')
    
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

# Validate that a file is a valid image with expected mime type
expect_image() {
    local file_path="$1"
    local expected_mime="$2"
    local description="$3"
    
    if [ ! -f "$file_path" ]; then
        log_error "$description: File not found: $file_path"
        exit 1
    fi
    
    # Use ImageMagick to get format and validate the image
    local format_output
    local magick_error
    local full_command="$IMAGEMAGICK_IDENTIFY_CMD -format \"%m\" \"$file_path\""
    format_output=$(eval "$full_command" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ] || [ -z "$format_output" ]; then
        log_error "$description: ImageMagick validation failed - corrupt or invalid image at $file_path"
        echo "Failed command: $full_command"
        echo "ImageMagick output:"
        echo "$format_output"
        exit 1
    fi
    
    # Convert ImageMagick format to mime type
    local mime_type=""
    case "$format_output" in
        "JPEG") mime_type="image/jpeg" ;;
        "PNG") mime_type="image/png" ;;
        "WEBP") mime_type="image/webp" ;;
        "GIF") mime_type="image/gif" ;;
        "TIFF") mime_type="image/tiff" ;;
        "BMP") mime_type="image/bmp" ;;
        *) mime_type="image/unknown" ;;
    esac
    
    # Check if mime type matches expected
    if [ "$mime_type" != "$expected_mime" ]; then
        log_error "$description: Wrong mime type - expected $expected_mime, got $mime_type (format: $format_output) at $file_path"
        exit 1
    fi
    
    log_success "$description: Valid $mime_type"
    return 0
}

# Validate that a file is a valid video with expected mime type
expect_video() {
    local file_path="$1"
    local expected_mime="$2"
    local description="$3"
    
    if [ ! -f "$file_path" ]; then
        log_error "$description: File not found: $file_path"
        exit 1
    fi
    
    # Use ffprobe to get format and validate the video
    local ffprobe_output
    local format_command="ffprobe -v quiet -show_format -show_entries format=format_name \"$file_path\""
    ffprobe_output=$(eval "$format_command" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "$description: ffprobe validation failed - not a valid video file at $file_path"
        echo "Failed command: $format_command"
        echo "ffprobe output:"
        echo "$ffprobe_output"
        exit 1
    fi
    
    local format_output=$(echo "$ffprobe_output" | grep "format_name=" | cut -d'=' -f2)
    if [ -z "$format_output" ]; then
        log_error "$description: ffprobe validation failed - no format found at $file_path"
        echo "Failed command: $format_command"
        echo "ffprobe output:"
        echo "$ffprobe_output"
        exit 1
    fi
    
    # Check that it has a video stream
    local stream_output
    local stream_command="ffprobe -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 \"$file_path\""
    stream_output=$(eval "$stream_command" 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ] || ! echo "$stream_output" | grep -q "video"; then
        log_error "$description: ffprobe validation failed - no video stream found at $file_path"
        echo "Failed command: $stream_command"
        echo "ffprobe stream output:"
        echo "$stream_output"
        exit 1
    fi
    
    # Convert ffprobe format to mime type
    local mime_type=""
    case "$format_output" in
        *"mp4"*) mime_type="video/mp4" ;;
        *"mov"*) mime_type="video/quicktime" ;;
        *"avi"*) mime_type="video/x-msvideo" ;;
        *"mkv"*) mime_type="video/x-matroska" ;;
        *"webm"*) mime_type="video/webm" ;;
        *"flv"*) mime_type="video/x-flv" ;;
        *) mime_type="video/unknown" ;;
    esac
    
    # Check if mime type matches expected
    if [ "$mime_type" != "$expected_mime" ]; then
        log_error "$description: Wrong mime type - expected $expected_mime, got $mime_type (format: $format_output) at $file_path"
        exit 1
    fi
    
    log_success "$description: Valid $mime_type"
    return 0
}

# Validate assets added to the database
validate_database_assets() {
    local db_dir="$1"
    local source_file="$2"
    local expected_mime="$3"
    local asset_type="$4"  # "image" or "video"
    local add_output="$5"  # CLI output from add command
    
    # Extract asset ID from the verbose CLI output
    local asset_id=$(echo "$add_output" | grep "Added file.*$source_file.*with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$asset_id" ]; then
        # Try to extract from "matches existing records" line for files already in database
        # The UUID is on the next line after "matches existing records:"
        asset_id=$(echo "$add_output" | grep -A 1 "matches existing records:" | tail -1 | sed 's/^[[:space:]]*//' | head -1)
    fi
    if [ -z "$asset_id" ]; then
        log_error "Failed to extract asset ID for $source_file from CLI output"
        log_error "Full CLI output:"
        echo "$add_output"
        exit 1
    fi
    
    log_info "Validating $asset_type assets for asset ID: $asset_id..."
    
    # Find the asset file using the asset ID
    local asset_file="$db_dir/assets/$asset_id"
    if [ ! -f "$asset_file" ]; then
        log_error "Asset file not found in database for asset ID: $asset_id"
        exit 1
    fi
    
    # Validate the main asset
    if [ "$asset_type" = "image" ]; then
        expect_image "$asset_file" "$expected_mime" "Original $asset_type asset (expected: $expected_mime)"
        
        # Check for display version (always JPEG)
        local display_file="$db_dir/display/$asset_id"
        if [ -f "$display_file" ]; then
            expect_image "$display_file" "image/jpeg" "Display version of $asset_type asset (expected: image/jpeg)"
        fi
        
        # Check for thumbnail (always JPEG)
        local thumb_file="$db_dir/thumb/$asset_id"
        if [ -f "$thumb_file" ]; then
            expect_image "$thumb_file" "image/jpeg" "Thumbnail version of $asset_type asset (expected: image/jpeg)"
        fi
    elif [ "$asset_type" = "video" ]; then
        expect_video "$asset_file" "$expected_mime" "Original $asset_type asset (expected: $expected_mime)"
        
        # Check for video thumbnail (should be a JPEG image)
        local thumb_file="$db_dir/thumb/$asset_id"
        if [ -f "$thumb_file" ]; then
            expect_image "$thumb_file" "image/jpeg" "Thumbnail of $asset_type asset (expected: image/jpeg)"
        fi
    fi
    
    log_success "All $asset_type assets validated successfully"
}


# Unified command invocation function
invoke_command() {
    local description="$1"
    local command="$2"
    local expected_exit_code="${3:-0}"
    local output_var_name="${4:-}"
    
    log_info "Running: $description"
    echo ""
    echo -e "${YELLOW}NODE_ENV:${NC} ${NODE_ENV:-'(not set)'}"
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
    
    local command_output=""
    local actual_exit_code=0
    
    # Ensure NODE_ENV is passed to the command - force it to testing for deterministic UUIDs
    local env_prefix="NODE_ENV=testing "
    local full_command="$env_prefix$command"
    
    if [ -n "$output_var_name" ]; then
        # Capture output and display it, ensuring all output is visible
        # Execute command and capture both output and exit code properly
        command_output=$(eval "$full_command" 2>&1)
        actual_exit_code=$?
        # Display the output after capturing it
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo "$command_output"
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
        
        # Store output in caller's variable
        eval "$output_var_name=\"\$command_output\""
    else
        # Execute without capturing output
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        eval "$full_command"
        actual_exit_code=$?
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
    fi
    
    # Check exit code and log results
    if [ $actual_exit_code -eq $expected_exit_code ]; then
        if [ $expected_exit_code -eq 0 ]; then
            log_success "$description"
            
            # Print root hash after successful psi commands that might affect the database
            if [[ "$command" == *"psi"* ]] || [[ "$command" == *"bun run start"* ]]; then
                # Extract database path from command
                local db_path=""
                if [[ "$command" == *"--db "* ]]; then
                    db_path=$(echo "$command" | sed -n 's/.*--db \([^ ]*\).*/\1/p')
                elif [ -n "$TEST_DB_DIR" ]; then
                    db_path="$TEST_DB_DIR"
                fi
                
                # Check if database exists and print root hash
                if [ -n "$db_path" ] && [ -d "$db_path" ] && [ -f "$db_path/.db/tree.dat" ]; then
                    echo ""
                    echo -e "[@@@@@@] ${YELLOW}[ROOT-HASH]${NC} $($(get_cli_command) debug root-hash --db "$db_path" --yes 2>/dev/null || echo "N/A")"
                    echo ""
                    echo -e "[@@@@@@] ${YELLOW}[MERKLE-TREE]${NC}"
                    $(get_cli_command) debug merkle-tree --db "$db_path" --yes 2>/dev/null | sed 's/^/[@@@@@@] /' || echo "[@@@@@@] N/A"
                fi
            fi
        else
            log_success "$description (expected failure with exit code $actual_exit_code)"
        fi
        return 0
    else
        if [ $expected_exit_code -eq 0 ]; then
            log_error "$description (exit code: $actual_exit_code)"
            # Special handling for macOS illegal instruction error
            if [ $actual_exit_code -eq 132 ] && [[ "$OSTYPE" == "darwin"* ]]; then
                log_error "Illegal instruction error on macOS - binary may be compiled for wrong architecture"
            fi
        else
            log_error "$description (expected failure but command succeeded)"
        fi
        exit 1  # Exit immediately on failure
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

# Cross-platform tree command
show_tree() {
    local directory="$1"
    local platform=$(detect_platform)
    
    log_info "Attempting to show directory structure for: $directory"
    
    # Try different tree command approaches
    if command -v tree &> /dev/null; then
        case "$platform" in
            "win")
                # Windows tree command syntax: tree [path] [options]
                # Try different Windows tree syntaxes
                if tree /f /a "$directory" 2>/dev/null; then
                    log_info "Used Windows tree command: tree /f /a $directory"
                elif cmd //c tree "$directory" //f //a 2>/dev/null; then
                    log_info "Used Windows tree via cmd: tree $directory //f //a"
                elif cmd //c tree "$directory" /f /a 2>/dev/null; then
                    log_info "Used Windows tree via cmd: tree $directory /f /a"
                else
                    # Fall back to Unix-style tree (if installed via chocolatey)
                    log_info "Windows tree failed, trying Unix-style tree"
                    tree "$directory" 2>/dev/null || {
                        log_warning "tree command failed, using ls -la instead"
                        ls -la "$directory"
                    }
                fi
                ;;
            *)
                # Linux/macOS tree command
                log_info "Using Unix-style tree command"
                tree "$directory" 2>/dev/null || {
                    log_warning "tree command failed, using ls -la instead"
                    ls -la "$directory"
                }
                ;;
        esac
    else
        log_warning "tree command not available, using ls -la instead"
        ls -la "$directory"
    fi
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
    rm -rf "./test/tmp"
    
    # Ensure tmp directory exists
    mkdir -p "./test/tmp"
    
    log_info "Building CLI executable for platform: $platform ($arch)"
    case "$platform" in
        "linux")
            invoke_command "Build Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build Windows executable" "bun run build-win"
            ;;
    esac
    
    log_info "Building frontend for platform: $platform"
    invoke_command "Build frontend" "bun run build-fe-$platform" || {
        log_warning "Frontend build failed, continuing anyway..."
    }
    test_passed
}

check_tools() {
    echo ""
    echo "=== CHECK TOOLS ==="
    
    log_info "Changing to CLI directory"
    if ! cd "$(dirname "$0")"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi
    
    local cli_command=$(get_cli_command)
    log_info "Using CLI command: $cli_command"
    
    # Verify NODE_ENV is set for deterministic UUID generation
    log_info "NODE_ENV is set to: ${NODE_ENV:-'(not set)'}"
    if [ "$NODE_ENV" = "testing" ]; then
        log_success "NODE_ENV=testing is set for deterministic UUID generation"
    else
        log_warning "NODE_ENV is not set to 'testing' - UUIDs may not be deterministic"
    fi
    
    log_info "Checking for required tools in system PATH"
    invoke_command "Check tools" "$(get_cli_command) tools --yes"
    echo ""
    
    log_info "Verifying tools are installed and working..."
    
    # Check that required tools exist and can print versions
    local tools_verified=true
    
    # Check ImageMagick - determine which version to use
    if command -v magick &> /dev/null; then
        local magick_output=$(magick --version || echo "")
        if [ -n "$magick_output" ]; then
            log_success "ImageMagick 7.x verified (using 'magick identify'):"
            echo "$magick_output"
            IMAGEMAGICK_IDENTIFY_CMD="magick identify"
        else
            log_error "ImageMagick magick command exists but cannot get version"
            tools_verified=false
        fi
    elif command -v identify &> /dev/null; then
        local identify_output=$(identify -version | head -1 || echo "")
        if [ -n "$identify_output" ]; then
            log_success "ImageMagick 6.x verified (using 'identify'):"
            echo "$identify_output"
            IMAGEMAGICK_IDENTIFY_CMD="identify"
        else
            log_error "ImageMagick identify command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ImageMagick not found in system PATH (tried both 'magick' and 'identify')"
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
    test_passed
}

test_create_database() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 1: CREATE DATABASE ==="
    
    invoke_command "Initialize new database" "$(get_cli_command) init --db $TEST_DB_DIR --yes"
    
    # Check if required files were created
    check_exists "$TEST_DB_DIR" "Database directory"
    check_exists "$TEST_DB_DIR/.db" "Database metadata directory"
    check_exists "$TEST_DB_DIR/.db/tree.dat" "Database tree file"
    check_exists "$TEST_DB_DIR/metadata" "Asset metadata directory"
    
    # Test initial state - database creation is verified by file existence checks above
    test_passed
}

test_view_media_files() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 2: VIEW LOCAL MEDIA FILES ==="
    
    # Capture the output to validate it
    local info_output
    invoke_command "Show info for test files" "$(get_cli_command) info $TEST_FILES_DIR/ --yes" 0 "info_output"
    
    # Check that info output doesn't contain "Type: undefined" which indicates a bug
    expect_output_string "$info_output" "Type: undefined" "Info output should not contain 'Type: undefined'" "false"
    
    # Check that each test file has the correct MIME type
    expect_output_string "$info_output" "Type: image/jpeg" "Info output should contain JPEG MIME type for test.jpg"
    expect_output_string "$info_output" "Type: image/png" "Info output should contain PNG MIME type for test.png"
    expect_output_string "$info_output" "Type: video/mp4" "Info output should contain MP4 MIME type for test.mp4"
    expect_output_string "$info_output" "Type: image/webp" "Info output should contain WebP MIME type for test.webp"
    test_passed
}

# Parameterized function to test adding a single file
test_add_file_parameterized() {
    local file_path="$1"
    local file_type="$2"
    local test_description="$3"
    local expected_mime="$4"
    local asset_type="$5"
    
    # Check if file exists
    check_exists "$file_path" "$file_type test file"
    
    # Get initial database state - count files in metadata collection
    # Use the info command output to track actual media files added
    local before_check=$($(get_cli_command) check --db $TEST_DB_DIR $file_path --yes 2>&1)
    local already_in_db=$(parse_numeric "$before_check" "Already added:")
    
    # Add the file and capture output with verbose logging
    local add_output
    invoke_command "$test_description" "$(get_cli_command) add --db $TEST_DB_DIR $file_path --verbose --yes" 0 "add_output"
    
    # Verify exactly one file was added (or was already there)
    if [ "$already_in_db" -eq "1" ]; then
        # File was already in database
        expect_output_value "$add_output" "Already added:" "1" "$file_type file already in database"
        expect_output_value "$add_output" "Files added:" "0" "$file_type file imported (should be 0 since already exists)"
    else
        # File should be newly added
        expect_output_value "$add_output" "Files added:" "1" "$file_type file imported"
        expect_output_value "$add_output" "Files failed:" "0" "$file_type file failed"
    fi
    
    # Check that the specific file is now in the database
    invoke_command "Check $file_type file added" "$(get_cli_command) check --db $TEST_DB_DIR $file_path --yes"
    
    # Validate the assets in the database
    validate_database_assets "$TEST_DB_DIR" "$file_path" "$expected_mime" "$asset_type" "$add_output"
}

test_add_png_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 3: ADD PNG FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.png" "PNG" "Add PNG file" "image/png" "image"
    
    test_passed
}

test_add_jpg_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 4: ADD JPG FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.jpg" "JPG" "Add JPG file" "image/jpeg" "image"
    
    test_passed
}

test_add_mp4_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 5: ADD MP4 FILE ==="
    
    test_add_file_parameterized "$TEST_FILES_DIR/test.mp4" "MP4" "Add MP4 file" "video/mp4" "video"
    
    test_passed
}

test_add_same_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 6: ADD SAME FILE (NO DUPLICATION) ==="
    
    # Try to re-add the PNG file (should not add it again)
    invoke_command "Re-add same file" "$(get_cli_command) add --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    
    invoke_command "Check file still in database" "$(get_cli_command) check --db $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    test_passed
}

test_add_multiple_files() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 7: ADD MULTIPLE FILES ==="
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        local add_output
        invoke_command "Add multiple files" "$(get_cli_command) add --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes" 0 "add_output"
        
        # Check that 2 files were imported
        expect_output_value "$add_output" "Files added:" "2" "Two files imported from multiple images directory"
        
        invoke_command "Check multiple files added" "$(get_cli_command) check --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
    test_passed
}

test_add_same_multiple_files() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 8: ADD SAME MULTIPLE FILES (NO DUPLICATION) ==="
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        invoke_command "Re-add multiple files" "$(get_cli_command) add --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
        
        invoke_command "Check multiple files still in database" "$(get_cli_command) check --db $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
    test_passed
}

test_database_summary() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 9: DATABASE SUMMARY ==="
    
    # Run summary command and capture output for verification
    local summary_output
    invoke_command "Display database summary" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "summary_output"
    
    # Check that summary contains expected fields
    expect_output_string "$summary_output" "Files imported:" "Summary contains files imported count"
    expect_output_string "$summary_output" "Total files:" "Summary contains total files count"
    expect_output_string "$summary_output" "Total size:" "Summary contains total size"
    expect_output_string "$summary_output" "Tree root hash:" "Summary contains hash"
    test_passed
}

test_database_list() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 10: DATABASE LIST ==="
    
    # Run list command and capture output for verification
    local list_output
    invoke_command "List database files" "$(get_cli_command) list --db $TEST_DB_DIR --page-size 10 --yes" 0 "list_output"
    
    # Check that list contains expected fields and patterns
    expect_output_string "$list_output" "Database Files" "List output contains header"
    expect_output_string "$list_output" "sorted by date" "List output contains sorting information"
    expect_output_string "$list_output" "Page 1" "List output contains page header"
    expect_output_string "$list_output" "Date:" "List output contains date information"
    expect_output_string "$list_output" "Size:" "List output contains size information"
    expect_output_string "$list_output" "Type:" "List output contains type information"
    
    # Check that it shows the expected number of files
    expect_output_string "$list_output" "End of results" "List shows end of results message"
    expect_output_string "$list_output" "Displayed 5 files total" "List shows correct total file count"
    test_passed
}

test_export_assets() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 11: EXPORT ASSETS ==="
    
    # Create export test directory
    local export_dir="./test/tmp/exports"
    mkdir -p "$export_dir"
    
    # Try to find assets in the database directory directly first
    local assets_dir="$TEST_DB_DIR/assets"
    local test_asset_id=""
    
    if [ -d "$assets_dir" ]; then
        test_asset_id=$(ls "$assets_dir" | head -1)
        log_info "Found asset files in assets directory"
    fi
    
    if [ -z "$test_asset_id" ]; then
        # Fallback: try to get a list of assets using the list command
        local list_output
        if invoke_command "List assets to find available asset IDs" "$(get_cli_command) list --db $TEST_DB_DIR --page-size 50 --yes" 0 "list_output"; then
            # Extract the first asset ID from the list output
            # The list output should contain lines with asset IDs
            test_asset_id=$(echo "$list_output" | grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" | head -1)
        fi
    fi
    
    if [ -z "$test_asset_id" ]; then
        log_error "Could not find any asset ID to test export with"
        log_info "List output:"
        echo "$list_output"
        log_info "Assets directory contents:"
        ls -la "$TEST_DB_DIR/assets" || echo "Assets directory not found"
        exit 1
    fi
    
    log_info "Using asset ID for export tests: $test_asset_id"
    
    # Test 1: Export original asset to specific file
    local export_output
    invoke_command "Export original asset to specific file" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/exported-original.png --verbose --yes" 0 "export_output"
    
    # Verify the exported file exists
    check_exists "$export_dir/exported-original.png" "Exported original file"
    
    # Check export output for success message
    expect_output_string "$export_output" "Successfully exported" "Export success message"
    
    # Test 2: Export display version to directory (if it exists)
    local display_file="$TEST_DB_DIR/display/$test_asset_id"
    if [ -f "$display_file" ]; then
        invoke_command "Export display version to directory" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/ --type display --verbose --yes"
        
        # Check if the display file was exported (name will depend on original filename)
        local exported_display_count=$(find "$export_dir" -name "*_display.*" | wc -l)
        if [ "$exported_display_count" -eq 0 ]; then
            log_warning "Display version export didn't create expected _display file"
        else
            log_success "Display version exported successfully"
        fi
    else
        log_info "Display version not available for asset $test_asset_id, skipping display export test"
    fi
    
    # Test 3: Export thumbnail version (if it exists)
    local thumb_file="$TEST_DB_DIR/thumb/$test_asset_id"
    if [ -f "$thumb_file" ]; then
        invoke_command "Export thumbnail version" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/thumb.jpg --type thumb --verbose --yes"
        
        check_exists "$export_dir/thumb.jpg" "Exported thumbnail file"
    else
        log_info "Thumbnail version not available for asset $test_asset_id, skipping thumbnail export test"
    fi
    
    # Test 4: Try to export non-existent asset (should fail)
    local invalid_asset_id="00000000-0000-0000-0000-000000000000"
    invoke_command "Export non-existent asset (should fail)" "$(get_cli_command) export --db $TEST_DB_DIR $invalid_asset_id $export_dir/should-not-exist.png --yes" 1
    
    # Test 5: Export the same asset explicitly as original type
    invoke_command "Export asset as original explicitly" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id $export_dir/explicit-original.png --type original --verbose --yes"
    
    check_exists "$export_dir/explicit-original.png" "Explicitly exported original file"
    
    log_success "All export tests completed successfully"
    test_passed
}

test_database_verify() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 12: DATABASE VERIFICATION ==="
    
    # Show database structure with tree command
    log_info "Showing database structure..."
    show_tree "$TEST_DB_DIR"
    
    # Run verify command and capture output for checking
    local verify_output
    invoke_command "Verify database integrity" "$(get_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"
    
    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Verify output contains total size"
    
    # Check that the database is in a good state (no new, modified, or removed files)
    expect_output_value "$verify_output" "Files imported:" "5" "File imported"
    expect_output_value "$verify_output" "Unmodified:" "24" "Unmodified files in verification"
    expect_output_value "$verify_output" "New:" "0" "New files in verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in verification"
    test_passed
}

test_database_verify_full() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 13: DATABASE VERIFICATION (FULL MODE) ==="
    
    print_test_name "13" "DATABASE VERIFICATION (FULL MODE)"
    
    # Run full verify command and capture output for checking
    local verify_output
    invoke_command "Verify database (full mode)" "$(get_cli_command) verify --db $TEST_DB_DIR --full --yes" 0 "verify_output"
    
    # Check that verification contains expected fields
    expect_output_string "$verify_output" "Files imported:" "Full verify output contains files imported count"
    expect_output_string "$verify_output" "Total files:" "Full verify output contains total files count"
    expect_output_string "$verify_output" "Total size:" "Full verify output contains total size"
    
    # Check that the database is in a good state even with full verification
    expect_output_value "$verify_output" "Unmodified:" "24" "Unmodified files in full verification"
    expect_output_value "$verify_output" "New:" "0" "New files in full verification"
    expect_output_value "$verify_output" "Modified:" "0" "Modified files in full verification"
    expect_output_value "$verify_output" "Removed:" "0" "Removed files in full verification"
    test_passed
}

test_detect_new_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 14: DETECT NEW FILE WITH VERIFY ==="
    
    local test_copy_dir="$TEST_DB_DIR-new-file-test"
    
    # Ensure source database exists before copying
    if [ ! -d "$TEST_DB_DIR" ]; then
        log_error "Source database not found at $TEST_DB_DIR. Run previous tests first."
        exit 1
    fi
    
    if [ ! -d "$TEST_DB_DIR/.db" ]; then
        log_error "Source database .db subdirectory not found at $TEST_DB_DIR/.db"
        exit 1
    fi
    
    # Create fresh copy of database for testing
    log_info "Creating fresh copy of database for new file test"
    
    # Ensure destination doesn't exist to avoid copying into subdirectory
    rm -rf "$test_copy_dir"
    
    cp -r "$TEST_DB_DIR" "$test_copy_dir"
    
    # Verify the copy includes the .db subdirectory
    if [ ! -d "$test_copy_dir/.db" ]; then
        log_error "Failed to copy .db subdirectory to $test_copy_dir"
        exit 1
    fi
    
    # Copy a new file into the database directory using cp command
    local new_file="$test_copy_dir/new-test-file.txt"
    echo "This is a new test file" > "$new_file"
    log_info "Added new file: $new_file"
    
    # Run verify and capture output - should detect the new file
    local verify_output
    invoke_command "Verify database with new file" "$(get_cli_command) verify --db $test_copy_dir --yes" 0 "verify_output"
    
    # Check that verify detected the new file
    expect_output_value "$verify_output" "New:" "1" "New file detected by verify"
    expect_output_value "$verify_output" "Unmodified:" "24" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files"
    expect_output_value "$verify_output" "Removed:" "0" "No removed files"
    
    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

test_detect_deleted_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 15: DETECT DELETED FILE WITH VERIFY ==="
    
    local test_copy_dir="$TEST_DB_DIR-deleted-file-test"
    
    # Ensure source database exists before copying
    if [ ! -d "$TEST_DB_DIR" ]; then
        log_error "Source database not found at $TEST_DB_DIR. Run previous tests first."
        exit 1
    fi
    
    if [ ! -d "$TEST_DB_DIR/.db" ]; then
        log_error "Source database .db subdirectory not found at $TEST_DB_DIR/.db"
        exit 1
    fi
    
    # Create fresh copy of database for testing
    log_info "Creating fresh copy of database for deleted file test"
    
    # Ensure destination doesn't exist to avoid copying into subdirectory
    rm -rf "$test_copy_dir"
    
    cp -r "$TEST_DB_DIR" "$test_copy_dir"
    
    # Verify the copy includes the .db subdirectory
    if [ ! -d "$test_copy_dir/.db" ]; then
        log_error "Failed to copy .db subdirectory to $test_copy_dir"
        exit 1
    fi
    
    # Find and delete the first file from the assets directory
    local file_to_delete=$(find "$test_copy_dir/assets" -type f | sort | head -1)
    if [ -n "$file_to_delete" ]; then
        local relative_path="${file_to_delete#$test_copy_dir/}"
        rm "$file_to_delete"
        log_info "Deleted file: $relative_path"
    else
        log_error "No file found in assets directory to delete"
        exit 1
    fi
    
    # Run verify and capture output - should detect the missing file
    local verify_output
    invoke_command "Verify database with deleted file" "$(get_cli_command) verify --db $test_copy_dir --yes" 0 "verify_output"
    
    # Check that verify detected the removed file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "23" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files"
    expect_output_value "$verify_output" "Removed:" "1" "Deleted file detected by verify"
    
    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

test_detect_modified_file() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 16: DETECT MODIFIED FILE WITH VERIFY ==="
    
    local test_copy_dir="$TEST_DB_DIR-modified-file-test"
    
    # Ensure source database exists before copying
    if [ ! -d "$TEST_DB_DIR" ]; then
        log_error "Source database not found at $TEST_DB_DIR. Run previous tests first."
        exit 1
    fi
    
    if [ ! -d "$TEST_DB_DIR/.db" ]; then
        log_error "Source database .db subdirectory not found at $TEST_DB_DIR/.db"
        exit 1
    fi
    
    # Create fresh copy of database for testing
    log_info "Creating fresh copy of database for modified file test"
    
    # Ensure destination doesn't exist to avoid copying into subdirectory
    rm -rf "$test_copy_dir"
    
    cp -r "$TEST_DB_DIR" "$test_copy_dir"
    
    # Verify the copy includes the .db subdirectory
    if [ ! -d "$test_copy_dir/.db" ]; then
        log_error "Failed to copy .db subdirectory to $test_copy_dir"
        exit 1
    fi
    
    # Find and modify the first file from the assets directory
    local file_to_modify=$(find "$test_copy_dir/assets" -type f | sort | head -1)
    if [ -n "$file_to_modify" ]; then
        local relative_path="${file_to_modify#$test_copy_dir/}"
        # Append some data to modify the file
        echo "Modified content" >> "$file_to_modify"
        log_info "Modified file: $relative_path"
    else
        log_error "No file found in assets directory to modify"
        exit 1
    fi
    
    # Run verify and capture output - should detect the modified file
    local verify_output
    invoke_command "Verify database with modified file" "$(get_cli_command) verify --db $test_copy_dir --yes" 0 "verify_output"
    
    # Check that verify detected the modified file
    expect_output_value "$verify_output" "New:" "0" "No new files"
    expect_output_value "$verify_output" "Unmodified:" "23" "Unmodified files"
    expect_output_value "$verify_output" "Modified:" "1" "Modified file detected by verify"
    expect_output_value "$verify_output" "Removed:" "0" "No removed files"
    
    # Clean up test copy
    rm -rf "$test_copy_dir"
    log_success "Cleaned up test database copy"
    test_passed
}

test_database_replicate() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 17: DATABASE REPLICATION ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Clean up any existing replica
    if [ -d "$replica_dir" ]; then
        log_info "Cleaning up existing replica directory"
        rm -rf "$replica_dir"
    fi
    
    # Run replicate command and capture output
    local replicate_output
    invoke_command "Replicate database" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "replicate_output"
    
    # Check if replication was successful
    expect_output_string "$replicate_output" "Replication completed successfully" "Database replication completed successfully"
    
    # Check expected values from replication output
    expect_output_value "$replicate_output" "Total files imported:" "5" "Total files imported"
    expect_output_value "$replicate_output" "Total files considered:" "24" "Total files considered"
    expect_output_value "$replicate_output" "Total files copied:" "24" "Files copied"
    expect_output_value "$replicate_output" "Skipped (unchanged):" "0" "Files skipped (first run)"
    
    # Check that replica was created
    check_exists "$replica_dir" "Replica database directory"
    check_exists "$replica_dir/.db" "Replica metadata directory"
    check_exists "$replica_dir/.db/tree.dat" "Replica tree file"
    test_passed
}

test_verify_replica() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 18: VERIFY REPLICA ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous test
    check_exists "$replica_dir" "Replica directory from previous test"
    
    # Verify replica contents match source
    local replica_verify_output
    invoke_command "Verify replica integrity" "$(get_cli_command) verify --db $replica_dir --yes" 0 "replica_verify_output"
    
    # Get source and replica summaries to compare file counts
    local source_summary
    invoke_command "Get source database summary" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "source_summary"
    
    local replica_summary
    invoke_command "Get replica database summary" "$(get_cli_command) summary --db $replica_dir --yes" 0 "replica_summary"
    
    # Extract and compare file counts
    local source_files=$(parse_numeric "$source_summary" "Total files:")
    local replica_files=$(parse_numeric "$replica_summary" "Total files:")
    expect_value "$replica_files" "$source_files" "Replica file count matches source"
    
    # Extract and compare node counts
    local source_nodes=$(parse_numeric "$source_summary" "Total nodes:")
    local replica_nodes=$(parse_numeric "$replica_summary" "Total nodes:")
    expect_value "$replica_nodes" "$source_nodes" "Replica node count matches source"
    
    # Verify the replica verify command also shows the expected counts
    expect_output_value "$replica_verify_output" "Total files:" "$source_files" "Replica verify shows correct file count"
    test_passed
}

test_database_replicate_second() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 19: SECOND DATABASE REPLICATION - NO CHANGES ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous test
    check_exists "$replica_dir" "Replica directory from previous test"
    
    # Run second replicate command and capture output
    local second_replication_output
    invoke_command "Second replication (no changes)" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "second_replication_output"
    
    # Check if replication was successful
    expect_output_string "$second_replication_output" "Replication completed successfully" "Second replication completed successfully"
    
    # Check expected values from second replication output
    expect_output_value "$second_replication_output" "Total files imported:" "5" "Total files imported"
    expect_output_value "$second_replication_output" "Total files considered:" "24" "Total files considered"
    expect_output_value "$second_replication_output" "Total files copied:" "0" "Files copied (all up to date)"
    expect_output_value "$second_replication_output" "Skipped (unchanged):" "24" "Files skipped (already exist)"
    test_passed
}

test_database_compare() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 20: DATABASE COMPARISON ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Test comparison between original and replica (should show no differences)
    local compare_output
    invoke_command "Compare original database with replica" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison shows no differences for identical databases
    expect_output_string "$compare_output" "No differences detected" "No differences detected between databases"
    
    
    # Test comparison with self (database vs itself)
    invoke_command "Compare database with itself" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $TEST_DB_DIR --yes"
    test_passed
}

test_compare_with_changes() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 21: COMPARE WITH CHANGES ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Add a new asset to the original database to create a difference
    local new_test_file="$TEST_FILES_DIR/test.webp"
    local webp_add_output
    invoke_command "Add new asset to original database" "$(get_cli_command) add --db $TEST_DB_DIR $new_test_file --verbose --yes" 0 "webp_add_output"
    
    # Validate the WEBP assets in the database
    validate_database_assets "$TEST_DB_DIR" "$new_test_file" "image/webp" "image" "$webp_add_output"
    
    # Test comparison between original and replica (should show differences after adding new asset)
    local compare_output
    invoke_command "Compare original database with replica after changes" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison detects the specific number of differences (new asset creates 8 differences)
    expect_output_string "$compare_output" "Databases have 8 differences" "Databases have 8 differences after adding new asset"
    test_passed
}

test_replicate_after_changes() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 22: REPLICATE AFTER CHANGES ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Replicate the changes from original to replica
    local replication_output
    invoke_command "Replicate changes to replica" "$(get_cli_command) replicate --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "replication_output"
    
    # Check that the 8 changed files were replicated
    expect_output_value "$replication_output" "Total files copied:" "8" "Files copied (the changes)"
    
    # Run compare command to verify databases are now identical again
    local compare_output
    invoke_command "Compare databases after replication" "$(get_cli_command) compare --db $TEST_DB_DIR --dest $replica_dir --yes" 0 "compare_output"
    
    # Check that comparison shows no differences after replication
    expect_output_string "$compare_output" "No differences detected" "No differences detected after replicating changes"
    test_passed
}

test_cannot_create_over_existing() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 23: CANNOT CREATE DATABASE OVER EXISTING ==="
    
    invoke_command "Fail to create database over existing" "$(get_cli_command) init --db $TEST_DB_DIR --yes" 1
    test_passed
}

test_repair_ok_database() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 24: REPAIR OK DATABASE (NO CHANGES) ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Run repair on the intact database using replica as source
    local repair_output
    invoke_command "Repair intact database" "$(get_cli_command) repair --db $TEST_DB_DIR --source $replica_dir --yes" 0 "repair_output"
    
    # Check that repair reports no issues found
    expect_output_string "$repair_output" "Database repair completed - no issues found" "Repair of OK database shows no issues"
    expect_output_value "$repair_output" "Repaired:" "0" "No files repaired"
    expect_output_value "$repair_output" "Unrepaired:" "0" "No files unrepaired"
    expect_output_value "$repair_output" "Modified:" "0" "No files modified"
    expect_output_value "$repair_output" "Removed:" "0" "No files removed"
    test_passed
}

test_remove_asset() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 25: REMOVE ASSET BY ID ==="
    
    # Find an asset ID to remove by listing the assets directory
    local assets_dir="$TEST_DB_DIR/assets"
    local test_asset_id=""
    
    if [ -d "$assets_dir" ]; then
        test_asset_id=$(ls "$assets_dir" | head -1)
        log_info "Found asset files in assets directory"
    fi
    
    if [ -z "$test_asset_id" ]; then
        # Fallback: try to get a list of assets using the list command
        local list_output
        if invoke_command "List assets to find available asset IDs" "$(get_cli_command) list --db $TEST_DB_DIR --page-size 50 --yes" 0 "list_output"; then
            # Extract the first asset ID from the list output
            test_asset_id=$(echo "$list_output" | grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" | head -1)
        fi
    fi
    
    if [ -z "$test_asset_id" ]; then
        log_error "Could not find any asset ID to test removal with"
        exit 1
    fi
    
    log_info "Using asset ID for removal test: $test_asset_id"
    
    # Get initial database summary before removal
    local before_summary
    invoke_command "Get database summary before removal" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "before_summary"
    local files_before=$(parse_numeric "$before_summary" "Files imported:")
    
    # Remove the asset
    local remove_output
    invoke_command "Remove asset from database" "$(get_cli_command) remove --db $TEST_DB_DIR $test_asset_id --verbose --yes" 0 "remove_output"
    
    # Check that removal was successful
    expect_output_string "$remove_output" "Successfully removed asset" "Asset removal success message"
    
    # Get database summary after removal
    local after_summary
    invoke_command "Get database summary after removal" "$(get_cli_command) summary --db $TEST_DB_DIR --yes" 0 "after_summary"
    local files_after=$(parse_numeric "$after_summary" "Files imported:")
    
    # Verify one less asset in the database
    local expected_files=$((files_before - 1))
    expect_value "$files_after" "$expected_files" "Asset count decreased by 1 after removal"
    
    # Try to export the removed asset (should fail)
    invoke_command "Try to export removed asset (should fail)" "$(get_cli_command) export --db $TEST_DB_DIR $test_asset_id ./test/tmp/should-fail.png --yes" 1
    
    # Verify the asset files no longer exist in storage
    local original_file="$TEST_DB_DIR/assets/$test_asset_id"
    local display_file="$TEST_DB_DIR/display/$test_asset_id"
    local thumb_file="$TEST_DB_DIR/thumb/$test_asset_id"
    
    log_info "Checking that all asset files have been deleted from storage..."
    
    # Check original asset file
    if [ -f "$original_file" ]; then
        log_error "Original asset file still exists after removal: $original_file"
        log_error "File size: $(stat -c%s "$original_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$original_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Original asset file removed from storage: $original_file"
    fi
    
    # Check display version file
    if [ -f "$display_file" ]; then
        log_error "Display asset file still exists after removal: $display_file"
        log_error "File size: $(stat -c%s "$display_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$display_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Display asset file removed from storage: $display_file"
    fi
    
    # Check thumbnail file
    if [ -f "$thumb_file" ]; then
        log_error "Thumbnail asset file still exists after removal: $thumb_file"
        log_error "File size: $(stat -c%s "$thumb_file" 2>/dev/null || echo "unknown")"
        log_error "File permissions: $(stat -c%A "$thumb_file" 2>/dev/null || echo "unknown")"
        exit 1
    else
        log_success "Thumbnail asset file removed from storage: $thumb_file"
    fi
    
    
    # Additional comprehensive check: scan all directories for any files containing the asset ID
    log_info "Performing comprehensive scan for any remaining files with asset ID..."
    local remaining_files=""
    
    # Check assets directory
    if [ -d "$TEST_DB_DIR/assets" ]; then
        remaining_files=$(find "$TEST_DB_DIR/assets" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in assets directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi
    
    # Check display directory
    if [ -d "$TEST_DB_DIR/display" ]; then
        remaining_files=$(find "$TEST_DB_DIR/display" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in display directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi
    
    # Check thumb directory
    if [ -d "$TEST_DB_DIR/thumb" ]; then
        remaining_files=$(find "$TEST_DB_DIR/thumb" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in thumb directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi
    
    # Check metadata directory
    if [ -d "$TEST_DB_DIR/metadata" ]; then
        remaining_files=$(find "$TEST_DB_DIR/metadata" -name "*$test_asset_id*" 2>/dev/null || true)
        if [ -n "$remaining_files" ]; then
            log_error "Found remaining files in metadata directory:"
            echo "$remaining_files"
            exit 1
        fi
    fi
    
    # Check the entire database directory recursively for any missed files
    local all_remaining_files=$(find "$TEST_DB_DIR" -name "*$test_asset_id*" -not -path "*/.db/*" 2>/dev/null || true)
    if [ -n "$all_remaining_files" ]; then
        log_error "Found remaining files containing asset ID in database directory:"
        echo "$all_remaining_files"
        log_error "These files should have been removed during asset deletion"
        exit 1
    fi
    
    log_success "Comprehensive file deletion check passed - no remaining files found for asset $test_asset_id"
    
    # Verify that the asset ID is no longer in the database listing
    log_info "Verifying asset ID is no longer in database listing..."
    local ls_output
    invoke_command "List database contents after removal" "$(get_cli_command) list --db $TEST_DB_DIR --yes" 0 "ls_output"
    
    # Check that the removed asset ID is not in the output
    if echo "$ls_output" | grep -q "$test_asset_id"; then
        log_error "Asset ID $test_asset_id still appears in database listing after removal"
        log_error "Database listing output:"
        echo "$ls_output"
        exit 1
    else
        log_success "Asset ID $test_asset_id no longer appears in database listing"
    fi
    
    # Run verify to make sure the database is still in a good state
    local verify_output
    invoke_command "Verify database after asset removal" "$(get_cli_command) verify --db $TEST_DB_DIR --yes" 0 "verify_output"
    
    # The database should still be consistent
    expect_output_value "$verify_output" "New:" "0" "No new files after removal"
    expect_output_value "$verify_output" "Modified:" "0" "No modified files after removal"
    
    log_success "Asset removal test completed successfully"
    test_passed
}

test_repair_damaged_database() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 26: REPAIR DAMAGED DATABASE ==="
    
    local replica_dir="$TEST_DB_DIR-replica"
    local damaged_dir="$TEST_DB_DIR-damaged"
    
    # Check that replica exists from previous tests
    check_exists "$replica_dir" "Replica directory from previous tests"
    
    # Create a copy of the database to damage
    log_info "Creating copy of database to damage"
    rm -rf "$damaged_dir"
    cp -r "$TEST_DB_DIR" "$damaged_dir"
    
    # Damage the database by:
    # 1. Deleting one file
    local file_to_delete=$(find "$damaged_dir/assets" -type f | head -1)
    if [ -n "$file_to_delete" ]; then
        local relative_path="${file_to_delete#$damaged_dir/}"
        rm "$file_to_delete"
        log_info "Deleted file to simulate damage: $relative_path"
    else
        log_error "No file found in assets directory to delete"
        exit 1
    fi
    
    # 2. Corrupting another file (if available)
    local file_to_corrupt=$(find "$damaged_dir/assets" -type f | head -1)
    if [ -n "$file_to_corrupt" ]; then
        local relative_path="${file_to_corrupt#$damaged_dir/}"
        echo "CORRUPTED FILE CONTENT - THIS IS NOT THE ORIGINAL DATA" > "$file_to_corrupt"
        log_info "Corrupted file to simulate damage: $relative_path"
    fi
    
    # Run verify to detect the damage
    log_info "Running verify to detect damage..."
    local verify_output
    invoke_command "Verify damaged database" "$(get_cli_command) verify --db $damaged_dir --yes --full" 0 "verify_output"
    
    # Verify should detect issues
    expect_output_string "$verify_output" "Database verification found issues" "Verify detects damage"
    
    # Run repair to fix the issues
    log_info "Running repair to fix issues..."
    local repair_output
    invoke_command "Repair damaged database" "$(get_cli_command) repair --db $damaged_dir --source $replica_dir --yes --full" 0 "repair_output"
    
    # Repair should fix the issues
    expect_output_string "$repair_output" "Database repair completed successfully" "Repair completes successfully"
    
    # Should have repaired at least one file
    local repaired_count=$(parse_numeric "$repair_output" "Repaired:")
    if [ "$repaired_count" -gt 0 ]; then
        log_success "Repair fixed $repaired_count files"
    else
        log_error "Repair should have fixed at least one file but repaired count is $repaired_count"
        exit 1
    fi
    
    # Verify the repair was successful
    log_info "Verifying repair was successful..."
    local final_verify_output
    invoke_command "Verify repaired database" "$(get_cli_command) verify --db $damaged_dir --yes" 0 "final_verify_output"
    
    expect_output_string "$final_verify_output" "Database verification passed - all files are intact" "Repaired database verifies successfully"
    
    # Clean up damaged database copy
    rm -rf "$damaged_dir"
    log_success "Cleaned up damaged database copy"
    test_passed
}



test_v2_database_summary() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 27: V2 DATABASE SUMMARY ACCESS ==="
    
    local v2_db_dir="../../test/dbs/v2"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    check_exists "$v2_db_dir/metadata" "V2 database metadata directory"
    
    # Test that summary command can read v2 database
    local summary_output
    invoke_command "Run summary on v2 database" "$(get_cli_command) summary --db $v2_db_dir --yes" 0 "summary_output"
    
    # Check that summary contains database version
    expect_output_string "$summary_output" "Database version: 2" "Summary shows v2 database version"
    
    log_success "Summary command successfully accessed v2 database"
    test_passed
}

test_v2_database_incompatible_commands() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 28: V2 DATABASE INCOMPATIBLE COMMANDS ==="
    
    local v2_db_dir="../../test/dbs/v2"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    
    # Test that verify command fails on v2 database with version error
    local verify_output
    invoke_command "Run verify on v2 database (should fail)" "$(get_cli_command) verify --db $v2_db_dir --yes" 1 "verify_output"
    
    # Check that error message mentions upgrade
    expect_output_string "$verify_output" "upgrade" "Error message suggests running upgrade command"
    
    log_success "Verify command correctly rejected v2 database"
    test_passed
}

test_v2_database_upgrade() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 29: V2 DATABASE UPGRADE TO V3 ==="
    
    local v2_db_dir="../../test/dbs/v2"
    local temp_v2_dir="./test/tmp/test-v2-upgrade"
    
    # Check that v2 database exists
    check_exists "$v2_db_dir" "V2 test database directory"
    
    # Create a copy of v2 database for upgrade testing
    log_info "Creating copy of v2 database for upgrade testing"
    rm -rf "$temp_v2_dir"
    cp -r "$v2_db_dir" "$temp_v2_dir"
    
    # Test upgrade command on v2 database
    local upgrade_output
    invoke_command "Upgrade v2 database to v3" "$(get_cli_command) upgrade --db $temp_v2_dir --yes" 0 "upgrade_output"
    
    # Check that upgrade was successful
    expect_output_string "$upgrade_output" "Database upgraded successfully to version 3" "Upgrade completed successfully"
    
    # Verify the upgraded database is now version 3
    local summary_output
    invoke_command "Check upgraded database version" "$(get_cli_command) summary --db $temp_v2_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 3" "Upgraded database is now version 3"
    
    # Test that verify command now works on upgraded database
    local verify_output
    invoke_command "Verify upgraded database" "$(get_cli_command) verify --db $temp_v2_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "Upgraded database verifies successfully"
    
    # Clean up temporary database
    rm -rf "$temp_v2_dir"
    log_success "Cleaned up temporary v2 upgrade database"
    test_passed
}

test_v3_database_upgrade_no_effect() {
    echo ""
    echo "============================================================================"
    echo "=== TEST 30: V3 DATABASE UPGRADE HAS NO EFFECT ==="
    
    local v3_db_dir="../../test/dbs/v3"
    local temp_v3_dir="./test/tmp/test-v3-upgrade"
    
    # Check that v3 database exists
    check_exists "$v3_db_dir" "V3 test database directory"
    
    # Create a copy of v3 database for upgrade testing
    log_info "Creating copy of v3 database for upgrade testing"
    rm -rf "$temp_v3_dir"
    cp -r "$v3_db_dir" "$temp_v3_dir"
    
    # Test upgrade command on v3 database (should have no effect)
    local upgrade_output
    invoke_command "Upgrade v3 database (should be no-op)" "$(get_cli_command) upgrade --db $temp_v3_dir --yes" 0 "upgrade_output"
    
    # Check that upgrade reports database is already current
    expect_output_string "$upgrade_output" "Database is already at the latest version (3)" "Upgrade reports database is already current"
    
    # Verify the database is still version 3
    local summary_output
    invoke_command "Check database version after upgrade" "$(get_cli_command) summary --db $temp_v3_dir --yes" 0 "summary_output"
    
    expect_output_string "$summary_output" "Database version: 3" "Database is still version 3"
    
    # Test that verify command still works
    local verify_output
    invoke_command "Verify v3 database after upgrade" "$(get_cli_command) verify --db $temp_v3_dir --yes" 0 "verify_output"
    
    expect_output_string "$verify_output" "Database verification passed" "V3 database verifies successfully after upgrade"
    
    # Clean up temporary database
    rm -rf "$temp_v3_dir"
    log_success "Cleaned up temporary v3 upgrade database"
    test_passed
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
    
    # Reset UUID counter for deterministic test results
    local UUID_COUNTER_FILE="./test/tmp/photosphere-test-uuid-counter"
    if [ -f "$UUID_COUNTER_FILE" ]; then
        log_info "Resetting test UUID counter"
        rm -f "$UUID_COUNTER_FILE"
        log_success "Removed UUID counter file"
    else
        log_info "UUID counter file not found (already clean)"
    fi
    
    # Remove the specific test database directory
    if [ -d "./test/tmp" ]; then
        log_info "Removing all test databases: ./test/tmp"
        rm -rf "./test/tmp"
        log_success "Removed ./test/tmp"
    else
        log_info "Test tmp directory not found (already clean): ./test/tmp"
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
    if [ -d "./test/tmp" ]; then
        rm -rf "./test/tmp"
        log_success "Removed existing test databases"
    else
        log_info "Test tmp directory not found (already clean)"
    fi
    
    # Clear local cache before running tests
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) debug clear-cache --yes" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    # Normalize test file timestamps for deterministic results
    log_info "Normalizing test file timestamps"
    if ! ../../test/normalize-timestamps.sh; then
        log_error "Failed to normalize test file timestamps"
        exit 1
    fi
    log_success "Test file timestamps normalized"
    
    # Check tools first
    check_tools
    
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
    test_database_list
    test_export_assets
    test_database_verify
    test_database_verify_full
    test_detect_new_file
    test_detect_deleted_file
    test_detect_modified_file
    test_database_replicate
    test_verify_replica
    test_database_replicate_second
    test_database_compare
    test_compare_with_changes
    test_replicate_after_changes
    test_cannot_create_over_existing
    test_repair_ok_database
    test_remove_asset
    test_repair_damaged_database
    test_v2_database_summary
    test_v2_database_incompatible_commands
    test_v2_database_upgrade
    test_v3_database_upgrade_no_effect
    
    # If we get here, all tests passed
    echo ""
    echo "======================================"
    echo "TEST SUMMARY"
    echo "======================================"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${GREEN}ALL SMOKE TESTS PASSED${NC}"
    
    # Generate comprehensive test report before cleanup
    echo ""
    mkdir -p ./tmp/reports
    local report_file="./tmp/reports/smoke-test-report.txt"
    generate_test_report "$report_file" "all"
    
    # Preserve test database for further inspection or hash capture
    echo ""
    log_info "Preserving test database for inspection"
    log_info "Test database available at: ./test/tmp/test-db"
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
        "check-tools")
            check_tools
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
        "list"|"10")
            test_database_list
            ;;
        "export"|"11")
            test_export_assets
            ;;
        "verify"|"12")
            test_database_verify
            ;;
        "verify-full"|"13")
            test_database_verify_full
            ;;
        "detect-new"|"14")
            test_detect_new_file
            ;;
        "detect-deleted"|"15")
            test_detect_deleted_file
            ;;
        "detect-modified"|"16")
            test_detect_modified_file
            ;;
        "replicate"|"17")
            test_database_replicate
            ;;
        "verify-replica"|"18")
            test_verify_replica
            ;;
        "replicate-second"|"19")
            test_database_replicate_second
            ;;
        "compare"|"20")
            test_database_compare
            ;;
        "compare-changes"|"21")
            test_compare_with_changes
            ;;
        "replicate-changes"|"22")
            test_replicate_after_changes
            ;;
        "no-overwrite"|"23")
            test_cannot_create_over_existing
            ;;
        "repair-ok"|"24")
            test_repair_ok_database
            ;;
        "remove"|"25")
            test_remove_asset
            ;;
        "repair-damaged"|"26")
            test_repair_damaged_database
            ;;
        "v2-summary"|"27")
            test_v2_database_summary
            ;;
        "v2-incompatible"|"28")
            test_v2_database_incompatible_commands
            ;;
        "v2-upgrade"|"29")
            test_v2_database_upgrade
            ;;
        "v3-upgrade-no-effect"|"30")
            test_v3_database_upgrade_no_effect
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
    
    # Clear local cache before running tests
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) debug clear-cache --yes" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    # Normalize test file timestamps for deterministic results
    log_info "Normalizing test file timestamps"
    if ! ../../test/normalize-timestamps.sh; then
        log_error "Failed to normalize test file timestamps"
        exit 1
    fi
    log_success "Test file timestamps normalized"
    
    # Check tools first before running any tests
    check_tools
    
    
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
                test_database_list
                test_export_assets
                test_database_verify
                test_database_verify_full
                test_detect_new_file
                test_detect_deleted_file
                test_detect_modified_file
                test_database_replicate
                test_verify_replica
                test_database_replicate_second
                test_database_compare
                test_compare_with_changes
                test_replicate_after_changes
                test_cannot_create_over_existing
                test_repair_ok_database
                test_remove_asset
                test_repair_damaged_database
                ;;
            "setup")
                test_setup
                ;;
            "check-tools")
                check_tools
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
            "list"|"10")
                test_database_list
                ;;
            "export"|"11")
                test_export_assets
                ;;
            "verify"|"12")
                test_database_verify
                ;;
            "verify-full"|"13")
                test_database_verify_full
                ;;
            "detect-new"|"14")
                test_detect_new_file
                ;;
            "detect-deleted"|"15")
                test_detect_deleted_file
                ;;
            "detect-modified"|"16")
                test_detect_modified_file
                ;;
            "replicate"|"17")
                test_database_replicate
                ;;
            "verify-replica"|"18")
                test_verify_replica
                ;;
            "replicate-second"|"19")
                test_database_replicate_second
                ;;
            "compare"|"20")
                test_database_compare
                ;;
            "compare-changes"|"21")
                test_compare_with_changes
                ;;
            "replicate-changes"|"22")
                test_replicate_after_changes
                ;;
            "no-overwrite"|"23")
                test_cannot_create_over_existing
                ;;
            "repair-ok"|"24")
                test_repair_ok_database
                ;;
            "remove"|"25")
                test_remove_asset
                ;;
            "repair-damaged"|"26")
                test_repair_damaged_database
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
    
    # Generate comprehensive test report
    echo ""
    mkdir -p ./tmp/reports
    local report_file="./tmp/reports/smoke-test-report.txt"
    generate_test_report "$report_file" "multiple"
    
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
    echo "  to <number>         - Run tests 1 through <number> (1-26, preserves database for inspection)"
    echo "  setup               - Build executable and frontend"
    echo "  check-tools         - Check required media processing tools are available"
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
    echo "  list (10)           - List files in database"
    echo "  export (11)         - Export assets by ID"
    echo "  verify (12)         - Verify database integrity"
    echo "  verify-full (13)    - Verify database integrity (full mode)"
    echo "  detect-new (14)     - Detect new file with verify"
    echo "  detect-deleted (15) - Detect deleted file with verify"
    echo "  detect-modified (16) - Detect modified file with verify"
    echo "  replicate (17)      - Replicate database to new location"
    echo "  verify-replica (18) - Verify replica integrity and match with source"
    echo "  replicate-second (19) - Second replication (no changes)"
    echo "  compare (20)        - Compare two databases"
    echo "  compare-changes (21) - Compare databases after adding changes"
    echo "  replicate-changes (22) - Replicate changes and verify sync"
    echo "  no-overwrite (23)   - Cannot create database over existing"
    echo "  repair-ok (24)      - Repair OK database (no changes)"
    echo "  remove (25)         - Remove asset by ID from database"
    echo "  repair-damaged (26) - Repair damaged database from replica"
    echo "  v2-summary (27)     - Run summary command on v2 database"
    echo "  v2-incompatible (28) - Test v2 database compatibility errors"
    echo "  v2-upgrade (29)     - Upgrade v2 database to v3"
    echo "  v3-upgrade-no-effect (30) - Test v3 upgrade has no effect"
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
    echo "  $0 setup,check-tools,all    # Build, check tools, and run all tests"
    echo "  $0 setup                    # Build executable and frontend only"
    echo "  $0 check-tools              # Check tools only"
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
        # Validate that end_test is a number between 1 and 26
        if [[ "$end_test" =~ ^[0-9]+$ ]] && [ "$end_test" -ge 1 ] && [ "$end_test" -le 26 ]; then
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
            if [ -d "./test/tmp" ]; then
                rm -rf "./test/tmp"
                log_success "Removed existing test databases"
            else
                log_info "Test tmp directory not found (already clean)"
            fi
            
            # Reset UUID counter for deterministic test results
            log_info "Resetting test UUID counter"
            UUID_COUNTER_FILE="./test/tmp/photosphere-test-uuid-counter"
            if [ -f "$UUID_COUNTER_FILE" ]; then
                rm -f "$UUID_COUNTER_FILE"
                log_success "Removed existing UUID counter file"
            else
                log_info "UUID counter file not found (already clean)"
            fi
            
            # Clear local cache before running tests
            log_info "Clearing local cache before running tests"
            invoke_command "Clear local cache" "$(get_cli_command) debug clear-cache --yes" || {
                log_warning "Failed to clear cache, continuing anyway..."
            }
            
            run_multiple_commands "$commands"
            return
        else
            log_error "Invalid test number: $end_test (must be 1-26)"
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
    
    # Check if running check-tools command
    if [ "$1" = "check-tools" ]; then
        check_tools
        exit 0
    fi
    
    # Running individual test
    echo "======================================"
    echo "Photosphere CLI Smoke Tests"
    echo "======================================"
    
    log_info "Running specific test: $1"
    
    # Clear local cache before running tests
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) debug clear-cache --yes" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    # Normalize test file timestamps for deterministic results
    log_info "Normalizing test file timestamps"
    if ! ../../test/normalize-timestamps.sh; then
        log_error "Failed to normalize test file timestamps"
        exit 1
    fi
    log_success "Test file timestamps normalized"
    
    # Check tools first before running individual test
    check_tools
    
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
    
    # Generate comprehensive test report
    echo ""
    mkdir -p ./tmp/reports
    local report_file="./tmp/reports/smoke-test-report.txt"
    generate_test_report "$report_file" "individual"
    
    exit 0
}

# Run main function
main "$@"