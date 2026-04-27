#!/bin/bash

# Shared library for Photosphere CLI smoke tests.
# Sourced by each individual test script.

# Absolute path to the smoke-tests/ directory (one level above lib/).
SMOKE_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
# Override TEST_TMP_DIR to run tests in parallel (e.g. TEST_TMP_DIR=./test/tmp-$$ ./smoke-tests.sh)
# ISOLATED_TEST_TMP_DIR is set per-script by the orchestrator for parallel runs and takes precedence.
TEST_TMP_DIR="${ISOLATED_TEST_TMP_DIR:-${TEST_TMP_DIR:-./test/tmp}}"
TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-images"
DUPLICATE_IMAGES_DIR="../../test/duplicate-images"

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Get test directory path for a given test number
get_test_dir() {
    local test_number="$1"
    echo "$TEST_TMP_DIR/$test_number"
}

# Get CLI command: default is from code (bun run start --); use --binary for built executable
get_cli_command() {
    if [ "$USE_BINARY" = "true" ]; then
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
    else
        echo "bun run start --"
    fi
}

# Get mk command: default is from code; use --binary for built executable
get_mk_command() {
    if [ "$USE_BINARY" = "true" ]; then
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        case "$platform" in
            "linux")
                echo "../mk-cli/bin/x64/linux/mk"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    echo "../mk-cli/bin/arm64/mac/mk"
                else
                    echo "../mk-cli/bin/x64/mac/mk"
                fi
                ;;
            "win")
                echo "../mk-cli/bin/x64/win/mk.exe"
                ;;
            *)
                echo "../mk-cli/bin/x64/linux/mk"  # Default to linux
                ;;
        esac
    else
        echo "bun run ../mk-cli/src/index.ts --"
    fi
}

# Get bdb command: default is from code; use --binary for built executable
get_bdb_command() {
    if [ "$USE_BINARY" = "true" ]; then
        local platform=$(detect_platform)
        local arch=$(detect_architecture)
        case "$platform" in
            "linux")
                echo "../bdb-cli/bin/x64/linux/bdb"
                ;;
            "mac")
                if [ "$arch" = "arm64" ]; then
                    echo "../bdb-cli/bin/arm64/mac/bdb"
                else
                    echo "../bdb-cli/bin/x64/mac/bdb"
                fi
                ;;
            "win")
                echo "../bdb-cli/bin/x64/win/bdb.exe"
                ;;
            *)
                echo "../bdb-cli/bin/x64/linux/bdb"  # Default to linux
                ;;
        esac
    else
        echo "bun run ../bdb-cli/src/index.ts"
    fi
}
# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

cleanup_and_show_summary() {
    local exit_code=$?
    echo ""
    
    # Show final status message - this should be the last thing printed
    echo ""
    echo "============================================================================"
    echo "============================================================================"
    if [ $TESTS_FAILED -eq 0 ] && [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ ALL SMOKE TESTS PASSED ✓✓✓${NC}"
        echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
    else
        echo -e "${RED}✗✗✗ SMOKE TESTS FAILED ✗✗✗${NC}"
        echo -e "${RED}Exit Code: $exit_code${NC}"
        if [ $TESTS_FAILED -gt 0 ]; then
            echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
            if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
                echo -e "${RED}Failed Tests:${NC}"
                for failed_test in "${FAILED_TESTS[@]}"; do
                    echo -e "${RED}  - $failed_test${NC}"
                done
            fi
        else
            echo -e "${RED}Test execution was aborted (likely due to an assertion failure)${NC}"
        fi
        if [ $TESTS_PASSED -gt 0 ]; then
            echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
        fi
    fi
    echo "============================================================================"
    echo "============================================================================"
    
    # Exit with the appropriate code
    exit $exit_code
}

# Global variable to store which ImageMagick command to use
# Preserve parent-exported value; auto-detect if not set
if [ -z "${IMAGEMAGICK_IDENTIFY_CMD:-}" ]; then
    if command -v magick &>/dev/null; then
        IMAGEMAGICK_IDENTIFY_CMD="magick identify"
    elif command -v identify &>/dev/null; then
        IMAGEMAGICK_IDENTIFY_CMD="identify"
    else
        IMAGEMAGICK_IDENTIFY_CMD=""
    fi
fi

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Print test header with double-line format
print_test_header() {
    local test_number="$1"
    local test_name="$2"
    echo ""
    echo "============================================================================"
    echo "============================================================================"
    echo "=== TEST $test_number: $test_name ==="
    echo "============================================================================"
    echo "============================================================================"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Array to store test results with hashes
TEST_RESULTS=()

# Check that merkle tree leaf nodes are in sorted order
check_merkle_tree_order() {
    local tree_file="$1"
    local description="${2:-merkle tree}"
    
    if [ ! -f "$tree_file" ]; then
        return 0  # Tree doesn't exist, skip check
    fi
    
    local mk_cmd=$(get_mk_command)
    local check_cmd="$mk_cmd check \"$tree_file\""
    local check_output
    local exit_code
    
    # Run the check command and capture output and exit code
    check_output=$($mk_cmd check "$tree_file" 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Leaf nodes are not in sorted order for $description"
        log_error "Tree file: $tree_file"
        log_error "Command: $check_cmd"
        log_error "Exit code: $exit_code"
        echo "$check_output"
        exit 1
    fi
}

# Verify that aggregate root hashes match between original and replica
verify_root_hashes_match() {
    local original_dir="$1"
    local replica_dir="$2"
    local description="${3:-databases}"
    
    log_info "Verifying aggregate root hashes match for $description"
    
    # Get aggregate root hash (includes both files and BSON database merkle trees)
    local original_hash_output
    local replica_hash_output
    invoke_command "Get original aggregate root hash" "$(get_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get replica aggregate root hash" "$(get_cli_command) root-hash --db $replica_dir --yes" 0 "replica_hash_output"
    
    local original_hash=$(echo "$original_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    local replica_hash=$(echo "$replica_hash_output" | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs)
    
    if [ "$original_hash" = "$replica_hash" ]; then
        log_success "Aggregate root hashes match: $original_hash"
    else
        log_error "Aggregate root hashes do not match"
        log_error "Original hash: $original_hash"
        log_error "Replica hash: $replica_hash"
        
        # Show merkle trees for debugging
        log_info "Showing merkle trees for original database:"
        $(get_cli_command) debug merkle-tree --db "$original_dir" --yes --records
        
        log_info "Showing merkle trees for replica database:"
        $(get_cli_command) debug merkle-tree --db "$replica_dir" --yes --records
        
        exit 1
    fi
}

# Test counting functions - only increment once per test function
test_passed() {
    ((TESTS_PASSED++))
    
    # Capture database hash if database exists
    if [ -d "$TEST_DB_DIR" ] && [ -f "$TEST_DB_DIR/.db/files.dat" ]; then
        local hash_output
        if hash_output=$($(get_cli_command) root-hash --db "$TEST_DB_DIR" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs); then
            TEST_RESULTS+=("PASS:$hash_output")
        else
            TEST_RESULTS+=("PASS:hash_failed")
        fi
        
        # Check that merkle tree leaf nodes are in sorted order
        check_merkle_tree_order "$TEST_DB_DIR/.db/files.dat" "main database"
    fi
}

test_failed() {
    local test_name="${1:-unknown}"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$test_name")
    
    # Capture database hash if database exists
    if [ -d "$TEST_DB_DIR" ] && [ -f "$TEST_DB_DIR/.db/files.dat" ]; then
        local hash_output
        if hash_output=$($(get_cli_command) root-hash --db "$TEST_DB_DIR" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs); then
            TEST_RESULTS+=("FAIL:$test_name:$hash_output")
        else
            TEST_RESULTS+=("FAIL:$test_name:hash_failed")
        fi
    fi
    
    # Exit immediately on any test failure
    log_error "Test failed: $test_name - aborting test suite"
    exit 1
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}


# Show test hash summary for local console output
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
    
    # Extract asset ID from the verbose CLI output (path in output may be absolute, so match "Added file" and "with ID" only)
    local asset_id=$(echo "$add_output" | grep "Added file.*to the database with ID" | sed -n 's/.*with ID "\([^"]*\)".*/\1/p' | head -1)
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
    local asset_file="$db_dir/asset/$asset_id"
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
                if [ -n "$db_path" ] && [ -d "$db_path" ] && [ -f "$db_path/.db/files.dat" ]; then
                    echo ""
                    echo -e "[@@@@@@] ${YELLOW}[ROOT-HASH]${NC} $($(get_cli_command) root-hash --db "$db_path" --yes 2>/dev/null || echo "N/A")"
                    echo ""
                    # echo -e "[@@@@@@] ${YELLOW}[MERKLE-TREE]${NC}"
                    # $(get_mk_command) show "$db_path/.db/files.dat" 2>/dev/null | sed 's/^/[@@@@@@] /' || echo "[@@@@@@] N/A"
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

# Usage: seed_vault_secret "shared:abc123" "s3-credentials" '{"label":"My S3",...}'
seed_vault_secret() {
    local secret_name="$1"
    local secret_type="$2"
    local secret_value="$3"

    mkdir -p "$PHOTOSPHERE_VAULT_DIR"
    local encoded_name
    encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$secret_name', safe=''))")
    local file_path="${PHOTOSPHERE_VAULT_DIR}/${encoded_name}.json"

    cat > "$file_path" <<VAULT_EOF
{
  "name": "$secret_name",
  "type": "$secret_type",
  "value": $(echo "$secret_value" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
}
VAULT_EOF
    chmod 600 "$file_path"
}

# Write a databases.json config file directly (removes any existing .toml so the migration path runs).
# Usage: seed_databases_config '[{"name":"my-photos","description":"","path":"/tmp/db"}]'
seed_databases_config() {
    local databases_json="$1"

    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"
    rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.toml"
    cat > "${PHOTOSPHERE_CONFIG_DIR}/databases.json" <<CONFIG_EOF
{
  "databases": $databases_json,
  "recentDatabasePaths": []
}
CONFIG_EOF
}
