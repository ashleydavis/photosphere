#!/bin/bash

# Shared library for Photosphere CLI smoke tests.
# Sourced by each individual test script.

# Absolute path to the smoke-tests/ directory (one level above lib/).
SMOKE_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# Absolute path to the repository root, for reaching the helper scripts under scripts/.
REPO_ROOT="$(cd "$SMOKE_TESTS_DIR/../../.." && pwd)"

# Get the Zig CLI command: the psi the runner built for this run into PHOTOSPHERE_ZIG_CLI_DIR, a
# directory of the run's own, never the shared zig-out. Fails loudly when no run built one, rather
# than letting a test run whatever an empty path resolves to.
get_zig_cli_command() {
    if [ -z "${PHOTOSPHERE_ZIG_CLI_DIR:-}" ]; then
        echo "The Zig CLI was asked for, but PHOTOSPHERE_ZIG_CLI_DIR is not set: run the test through smoke-tests.sh, which builds it." >&2
        return 1
    fi
    case "$(uname -s)" in
        CYGWIN*|MINGW*|MSYS*)
            printf '%s/bin/psi.exe\n' "$PHOTOSPHERE_ZIG_CLI_DIR"
            ;;
        *)
            printf '%s/bin/psi\n' "$PHOTOSPHERE_ZIG_CLI_DIR"
            ;;
    esac
}

# The Zig CLI every test here runs, which the runner built for this run.
get_zig_cli_command > /dev/null || exit 1

# LAN pairing codes, allocated so a test cannot take one another run on the machine is using.
source "$REPO_ROOT/scripts/lib/test-lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
# Where this test keeps its fixtures, vault, config and scratch space. The orchestrator allocates a
# directory per test and passes it in; a test run straight from the command line inherits whatever is
# set, and otherwise gets a directory allocated for it, never one shared with another run.
export TEST_TMP_DIR="${TEST_TMP_DIR:-$(photosphere_test_temp_dir cli-test)}"

# The same directory again under Photosphere's own temp-directory setting, so the temporary files
# every psi process this test starts writes (the log directory among them) land inside this test's
# own directory rather than in a location shared with every other test on the machine.
export PHOTOSPHERE_TMP_DIR="$TEST_TMP_DIR"

# And the hash caches, which are not temporary files: they live with the user's own data so they
# outlive a restart, so pointing the temp directory at this test says nothing about where they go.
export PHOTOSPHERE_CACHE_DIR="$TEST_TMP_DIR/cache"

TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-files"
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

# Check that the leaf nodes of a database's files merkle tree are in sorted order. A database with no
# files tree yet has nothing to check.
# Usage: check_merkle_tree_order <database> [description]
check_merkle_tree_order() {
    local db_dir="$1"
    local description="${2:-merkle tree}"

    if [ ! -f "$db_dir/.db/files.dat" ]; then
        return 0
    fi

    local zig_cli_cmd=$(get_zig_cli_command)
    local check_cmd="$zig_cli_cmd debug merkle-check --db \"$db_dir\" --yes"
    local check_output
    local exit_code

    # Run the check command and capture output and exit code
    check_output=$($zig_cli_cmd debug merkle-check --db "$db_dir" --yes 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Leaf nodes are not in sorted order for $description"
        log_error "Database: $db_dir"
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
    invoke_command "Get original aggregate root hash" "$(get_zig_cli_command) root-hash --db $original_dir --yes" 0 "original_hash_output"
    invoke_command "Get replica aggregate root hash" "$(get_zig_cli_command) root-hash --db $replica_dir --yes" 0 "replica_hash_output"
    
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
        $(get_zig_cli_command) debug merkle-tree --db "$original_dir" --yes --records

        log_info "Showing merkle trees for replica database:"
        $(get_zig_cli_command) debug merkle-tree --db "$replica_dir" --yes --records
        
        exit 1
    fi
}

# Test counting functions - only increment once per test function
test_passed() {
    ((TESTS_PASSED++))
    
    # Capture database hash if database exists
    if [ -d "$TEST_DB_DIR" ] && [ -f "$TEST_DB_DIR/.db/files.dat" ]; then
        local hash_output
        if hash_output=$($(get_zig_cli_command) root-hash --db "$TEST_DB_DIR" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs); then
            TEST_RESULTS+=("PASS:$hash_output")
        else
            TEST_RESULTS+=("PASS:hash_failed")
        fi
        
        # Check that merkle tree leaf nodes are in sorted order
        check_merkle_tree_order "$TEST_DB_DIR" "main database"
    fi
}

test_failed() {
    local test_name="${1:-unknown}"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$test_name")
    
    # Capture database hash if database exists
    if [ -d "$TEST_DB_DIR" ] && [ -f "$TEST_DB_DIR/.db/files.dat" ]; then
        local hash_output
        if hash_output=$($(get_zig_cli_command) root-hash --db "$TEST_DB_DIR" --yes 2>/dev/null | tail -1 | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g' | xargs); then
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
#
# The label has to be present. parse_numeric returns its default of 0 when it finds no match, so an
# assertion expecting 0 used to pass just as readily against output that never mentioned the label at
# all: twenty assertions of the form expect_output_value "$output" "Removed:" "0" would not have
# noticed the CLI dropping, renaming or failing to print that line. Checking for the label first
# turns "the number is not there" into a failure instead of a zero.
expect_output_value() {
    local output="$1"
    local pattern="$2"
    local expected="$3"
    local description="$4"

    if ! echo "$output" | grep -q "$pattern"; then
        log_error "$description: the output contains no '$pattern' line, so there is no value to check"
        echo "$output"
        exit 1
    fi

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
#
# A pattern that is not in the output is answered with the given default, and with nothing at all when
# no default was given. It used to answer 0 either way, and 0 is a number a test will happily compare
# against: "the summary line is missing from what we captured" was reported as "the app enumerated 0
# objects", and that description sent three separate investigations at S3 when the fault was a command
# losing the end of its own output. A caller that wants 0 for an absent pattern says so by passing it.
parse_numeric() {
    local output="$1"
    local pattern="$2"
    local default_given=0
    local default_value=""
    if [ "$#" -ge 3 ]; then
        default_given=1
        default_value="$3"
    fi

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
    
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    if [ "$default_given" -eq 1 ]; then
        echo "$default_value"
        return 0
    fi

    # To stderr, and nothing to stdout: this runs inside a command substitution, so anything said on
    # stdout would be captured as the answer, and an `exit` here would end only the subshell.
    {
        echo -e "${RED}[FAIL]${NC} No number could be read for '$pattern', which is not in the output."
        echo "  The last few lines of what was searched:"
        echo "$clean_output" | tail -5 | sed 's/^/    /'
    } >&2
    return 1
}

# Prints the mime type a media file's first bytes say it is, or nothing when they match no format the
# smoke tests use. An ISO media file is QuickTime when its brand is "qt  " and MP4 otherwise, and a
# Matroska file is WebM when "webm" appears as its document type in the first bytes.
# Usage: media_mime_from_header <file path>
media_mime_from_header() {
    local file_path="$1"
    local header
    header=$(od -An -tx1 -N64 "$file_path" | tr -d ' \n')
    case "$header" in
        ffd8ff*) echo "image/jpeg" ;;
        89504e470d0a1a0a*) echo "image/png" ;;
        52494646????????57454250*) echo "image/webp" ;;
        52494646????????41564920*) echo "video/x-msvideo" ;;
        47494638*) echo "image/gif" ;;
        49492a00*|4d4d002a*) echo "image/tiff" ;;
        424d*) echo "image/bmp" ;;
        ????????667479707174*) echo "video/quicktime" ;;
        ????????66747970*) echo "video/mp4" ;;
        1a45dfa3*7765626d*) echo "video/webm" ;;
        1a45dfa3*) echo "video/x-matroska" ;;
        464c56*) echo "video/x-flv" ;;
    esac
}

# Prints the file extension psi takes a mime type from, since `psi info` reads the type from the
# extension rather than the content.
# Usage: media_extension_for_mime <mime type>
media_extension_for_mime() {
    case "$1" in
        "image/jpeg") echo "jpg" ;;
        "image/png") echo "png" ;;
        "image/webp") echo "webp" ;;
        "image/gif") echo "gif" ;;
        "image/tiff") echo "tiff" ;;
        "image/bmp") echo "bmp" ;;
        "video/mp4") echo "mp4" ;;
        "video/quicktime") echo "mov" ;;
        "video/x-msvideo") echo "avi" ;;
        "video/x-matroska") echo "mkv" ;;
        "video/webm") echo "webm" ;;
        "video/x-flv") echo "flv" ;;
    esac
}

# Validates that a file is a photo or video of the expected mime type that the media tools built
# into psi can decode. The type comes from the file's first bytes, and the decode from `psi info`
# printing the file's dimensions, run on a copy whose extension names that type. Exits on failure.
# Usage: expect_media <file path> <expected mime type> <description>
expect_media() {
    local file_path="$1"
    local expected_mime="$2"
    local description="$3"

    if [ ! -f "$file_path" ]; then
        log_error "$description: File not found: $file_path"
        exit 1
    fi

    local mime_type
    mime_type=$(media_mime_from_header "$file_path")
    if [ "$mime_type" != "$expected_mime" ]; then
        log_error "$description: Wrong mime type - expected $expected_mime, got ${mime_type:-an unknown format} at $file_path"
        echo "First bytes:"
        od -An -tx1 -N16 "$file_path"
        exit 1
    fi

    local copy_dir
    copy_dir=$(photosphere_test_temp_dir expect-media)
    local copy_path="$copy_dir/media.$(media_extension_for_mime "$mime_type")"
    cp "$file_path" "$copy_path"
    local info_output
    info_output=$($(get_zig_cli_command) info "$copy_path" --yes 2>&1)
    local info_exit_code=$?
    rm -f "$copy_path"
    rmdir "$copy_dir"

    if [ $info_exit_code -ne 0 ] || ! echo "$info_output" | grep -q "Dimensions:"; then
        log_error "$description: The built-in media tools could not decode $file_path"
        echo "psi info output:"
        echo "$info_output"
        exit 1
    fi

    log_success "$description: Valid $mime_type"
    return 0
}

# Validates that a file is an image of the expected mime type. See expect_media.
# Usage: expect_image <file path> <expected mime type> <description>
expect_image() {
    expect_media "$1" "$2" "$3"
}

# Validates that a file is a video of the expected mime type. See expect_media.
# Usage: expect_video <file path> <expected mime type> <description>
expect_video() {
    expect_media "$1" "$2" "$3"
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
            
            # Print root hash after successful psi commands that might affect the database. Not after a
            # verify (verify_database sets SKIP_ROOT_HASH_PRINT), which reads the database and changes
            # nothing, so the hash would be the one printed after the step it checks.
            if [[ "$command" == *"psi"* ]] && [ "${SKIP_ROOT_HASH_PRINT:-}" != "true" ]; then
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
                    echo -e "[@@@@@@] ${YELLOW}[ROOT-HASH]${NC} $($(get_zig_cli_command) root-hash --db "$db_path" --yes 2>/dev/null || echo "N/A")"
                    echo ""
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

# Runs psi verify on a database the Zig CLI has just created or modified, and fails the test unless it
# passes, so every database the Zig CLI writes is checked by reading it back. Any further arguments (a
# --key) go to verify.
# Usage: verify_database <database> [verify arguments...]
verify_database() {
    local database_dir="$1"
    shift
    local verify_arguments=""
    if [ $# -gt 0 ]; then
        verify_arguments="$(printf ' %q' "$@")"
    fi
    # The verify takes its deterministic test UUIDs from a counter of its own, so checking a database
    # does not move the ids the commands under test hand out next, which the tests assert on.
    local verify_counter_dir="$TEST_TMP_DIR/verify-uuid-counter"
    mkdir -p "$verify_counter_dir"
    SKIP_ROOT_HASH_PRINT=true invoke_command "Verify $database_dir" "TEST_TMP_DIR=\"$verify_counter_dir\" $(get_zig_cli_command) verify --db \"$database_dir\"$verify_arguments --yes"
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

# Seeds one secret into the plaintext vault's single vault.json file, which holds every secret keyed
# by its name. The name goes into a JSON key, so a colon, slash or space in it needs no encoding.
# The merge is a read-modify-write, so seeding a second secret keeps the first. An absent vault file
# starts from an empty object, and a vault file that does not parse fails the test outright rather
# than being silently replaced with a fresh one.
# Usage: seed_vault_secret "shared:abc123" "s3-credentials" '{"region":"us-east-1",...}'
seed_vault_secret() {
    local secret_name="$1"
    local secret_type="$2"
    local secret_value="$3"

    mkdir -p "$PHOTOSPHERE_VAULT_DIR"
    local vault_file="${PHOTOSPHERE_VAULT_DIR}/vault.json"
    if [ ! -f "$vault_file" ]; then
        printf '%s' '{}' > "$vault_file"
    fi

    # jq --arg passes each value in as data, never as text spliced into a template, so a name or
    # value containing a quote, a backslash or a newline is escaped by jq rather than becoming
    # syntax. jq prints a trailing newline the vault's own writer does not, so printf strips it.
    local merged
    if ! merged=$(jq -c --arg name "$secret_name" --arg type "$secret_type" --arg value "$secret_value" \
        '. + {($name): {name: $name, type: $type, value: $value}}' "$vault_file"); then
        log_error "Vault file $vault_file is not valid JSON"
        return 1
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

# Starts the local MinIO S3 emulator in the given state directory and reads back what it bound.
#
# On return S3_EMULATOR_PORT, S3_EMULATOR_BUCKET, S3_EMULATOR_ACCESS_KEY and S3_EMULATOR_SECRET_KEY
# are exported (from the emulator's own env file), along with S3_ENDPOINT, the http:// URL the CLI
# reaches it at. The endpoint is addressed by IP, never "localhost": without path-style addressing
# the SDK puts the bucket into the hostname, which on a machine that resolves *.localhost reaches the
# server but names no bucket, so the database reads back empty instead of failing.
#
# A failure to start is fatal: an S3 test that cannot get a server must fail, never skip.
# Usage: start_s3_emulator <state-dir>
start_s3_emulator() {
    local state_dir="$1"

    mkdir -p "$state_dir"
    if ! (cd "$REPO_ROOT" && bun run s3-emulator start "$state_dir"); then
        log_error "Could not start the local S3 emulator"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$state_dir/env"
    export S3_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
    log_info "S3 emulator at $S3_ENDPOINT, bucket $S3_EMULATOR_BUCKET"
}

# Stops the S3 emulator recorded in the given state directory. Never fails, including when nothing
# was ever started, so it is safe in an unconditional trap.
# Usage: stop_s3_emulator <state-dir>
stop_s3_emulator() {
    local state_dir="$1"
    (cd "$REPO_ROOT" && bun run s3-emulator stop "$state_dir") >/dev/null 2>&1 || true
    return 0
}

# Exports the emulator's credentials as the AWS_* variables the CLI falls back to when the database
# entry names no vault secret. This is the "point the CLI at a bucket" path a user takes with a
# self-hosted server. Requires start_s3_emulator to have run first.
export_s3_env_credentials() {
    export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
    export AWS_ENDPOINT="$S3_ENDPOINT"
    export AWS_REGION="us-east-1"
}

# Writes the emulator's credentials into the vault as an s3-credentials secret, which is the
# credential path the desktop and mobile apps actually use. Requires start_s3_emulator to have run.
# Usage: seed_s3_vault_secret <secret-name>
seed_s3_vault_secret() {
    local secret_name="$1"

    seed_vault_secret "$secret_name" "s3-credentials" \
        "{\"region\":\"us-east-1\",\"accessKeyId\":\"$S3_EMULATOR_ACCESS_KEY\",\"secretAccessKey\":\"$S3_EMULATOR_SECRET_KEY\",\"endpoint\":\"$S3_ENDPOINT\"}"
}

#
# Returns 0 when the given database path is a plain local directory, which is the only kind that can
# be produced by copying one.
#
# The S3 tests pass their path with the quotes still around it, because invoke_command evals what it
# is given, so those are stripped before the scheme is looked at.
# Usage: is_local_db_path <db-path>
#
is_local_db_path() {
    local db_path="$1"
    db_path="${db_path#\"}"
    db_path="${db_path%\"}"
    case "$db_path" in
        s3:*|fs:*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

#
# Creates a database holding the 5 standard test files (PNG, JPG, MP4, 2 from multiple-files).
#
# A copy of the run's prebuilt fixture when there is one, because 18 tests each spent about 5 seconds
# building the identical 7.5MB database and copying it takes under a second. PHOTOSPHERE_SMOKE_FIXTURE_5_FILES
# names the directory the runner built it in, holding the database at db/ and the UUID counter beside
# it.
#
# The counter is copied with it, and that is not tidiness. TestUuidGenerator counts from zero per
# TEST_TMP_DIR, so a test that copied the fixture and then added an asset would be handed counter 1
# again and mint a UUID the copied database already contains.
#
# Falls back to building the database when there is no fixture (a single test run from the command
# line) or when the destination is not a local directory (the S3 tests, whose database lives in a
# bucket and cannot be copied into place).
# Usage: create_db_with_5_files <db-path>
#
create_db_with_5_files() {
    local db_dir="$1"
    if [ -n "${PHOTOSPHERE_SMOKE_FIXTURE_5_FILES:-}" ] && [ -d "${PHOTOSPHERE_SMOKE_FIXTURE_5_FILES:-}/db" ] && is_local_db_path "$db_dir"; then
        log_info "Copying the prebuilt five-file database from $PHOTOSPHERE_SMOKE_FIXTURE_5_FILES"
        mkdir -p "$(dirname "$db_dir")"
        cp -r "$PHOTOSPHERE_SMOKE_FIXTURE_5_FILES/db" "$db_dir"
        mkdir -p "$TEST_TMP_DIR"
        cp "$PHOTOSPHERE_SMOKE_FIXTURE_5_FILES/photosphere-test-uuid-counter" "$TEST_TMP_DIR/photosphere-test-uuid-counter"
        return 0
    fi

    invoke_command "Initialize database" "$(get_zig_cli_command) init --db $db_dir --yes"
    verify_database "$db_dir"
    populate_db_with_5_files "$db_dir"
}

# Populate a pre-initialized database with the 5 standard test files (PNG, JPG, MP4, 2 from multiple-files).
populate_db_with_5_files() {
    local db_dir="$1"
    invoke_command "Add PNG file" "$(get_zig_cli_command) add --db $db_dir $TEST_FILES_DIR/test.png --yes"
    verify_database "$db_dir"
    invoke_command "Add JPG file" "$(get_zig_cli_command) add --db $db_dir $TEST_FILES_DIR/test.jpg --yes"
    verify_database "$db_dir"
    invoke_command "Add MP4 file" "$(get_zig_cli_command) add --db $db_dir $TEST_FILES_DIR/multiple-files/test.mp4 --yes"
    verify_database "$db_dir"
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        invoke_command "Add multiple images" "$(get_zig_cli_command) add --db $db_dir $MULTIPLE_IMAGES_DIR/ --yes"
        verify_database "$db_dir"
    fi
}

# Writes databases.toml in the config directory, holding the given database entries and no recent
# databases, before the CLI runs. Each entry takes name, path and optionally description, origin,
# s3Key, encryptionKey and geocodingKey, written as the keys buildDatabasesConfigToml in
# packages-zig/node-api-zig/src/lib/databases-config.worker.zig writes them. It is written here, not
# with `psi dbs add`, because dbs add refuses a key that is not in the vault, and the tests seed
# entries naming keys they never store. Every value goes through jq's tojson, so a quote, a backslash
# or a newline in it comes out escaped, which TOML reads the same way. A list that is not valid JSON
# fails the test.
# Usage: seed_databases_config '[{"name":"my-photos","description":"","path":"/tmp/db"}]'
seed_databases_config() {
    local databases_json="$1"

    mkdir -p "$PHOTOSPHERE_CONFIG_DIR"
    local databases_toml
    if ! databases_toml=$(printf '%s' "$databases_json" | jq -r '
        def optional_key($toml_key; $value): if $value then "\n\($toml_key) = \($value | tojson)" else "" end;
        if length == 0 then
            "recent_database_names = []\ndatabases = []"
        else
            "recent_database_names = []\n" + (map(
                "\n[[databases]]"
                + "\nname = \(.name | tojson)"
                + "\ndescription = \((.description // "") | tojson)"
                + "\npath = \(.path | tojson)"
                + optional_key("origin"; .origin)
                + optional_key("s3_key"; .s3Key)
                + optional_key("encryption_key"; .encryptionKey)
                + optional_key("geocoding_key"; .geocodingKey)
            ) | join("\n"))
        end'); then
        log_error "The database entries to seed are not a valid JSON list: $databases_json"
        exit 1
    fi
    printf '%s\n\n' "$databases_toml" > "${PHOTOSPHERE_CONFIG_DIR}/databases.toml"
}

# Writes a PNG whose content differs from every other call's: a copy of the fixture test/test.png
# with 64 random bytes after its IEND chunk, which a PNG reader ignores. Logs and returns 1 when the
# copy or the random bytes cannot be written.
# Usage: generate_png_file <file path>
generate_png_file() {
    local file_path="$1"

    if ! cp "$REPO_ROOT/test/test.png" "$file_path" || ! head -c 64 /dev/urandom >> "$file_path"; then
        log_error "Failed to generate PNG file: $file_path"
        return 1
    fi

    return 0
}

# Writes a valid MP4 video of more than <padding bytes>: a copy of the fixture
# test/multiple-files/test.mp4 followed by a top-level MP4 `free` box holding that many random bytes.
# A video reader skips a `free` box, so the file decodes as the fixture does, and the random bytes
# keep it from compressing in transit. The padding must be under 4 GiB, the most a 32-bit box size
# holds. Logs and returns 1 when the file cannot be written.
# Usage: generate_large_video_file <file path> <padding bytes>
generate_large_video_file() {
    local file_path="$1"
    local padding_bytes="$2"
    local box_size_hex
    box_size_hex=$(printf '%08x' $((padding_bytes + 8)))
    local box_size_escaped="\\x${box_size_hex:0:2}\\x${box_size_hex:2:2}\\x${box_size_hex:4:2}\\x${box_size_hex:6:2}"

    if ! cp "$REPO_ROOT/test/multiple-files/test.mp4" "$file_path" \
        || ! printf "${box_size_escaped}free" >> "$file_path" \
        || ! head -c "$padding_bytes" /dev/urandom >> "$file_path"; then
        log_error "Failed to generate the large video file: $file_path"
        return 1
    fi

    return 0
}
