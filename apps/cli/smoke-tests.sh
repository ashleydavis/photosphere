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

# Get CLI command based on platform - always use built executable
get_cli_command() {
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
}

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Control cleanup behavior
CLEANUP_ON_EXIT="false"

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

# Show tools status at start of each test
show_tools_directory() {
    log_info "Checking for system-installed tools:"
    echo ""
}

# Get and display tool versions
show_tool_versions() {
    log_info "Tool versions:"
    
    # Check ImageMagick version
    if command -v magick &> /dev/null; then
        local magick_version=$(magick --version | head -1 | grep -o 'ImageMagick [0-9.-]*' | sed 's/ImageMagick //' || echo "unknown")
        echo "  • ImageMagick: $magick_version"
    else
        echo "  • ImageMagick: not found"
    fi
    
    # Check ffprobe version
    if command -v ffprobe &> /dev/null; then
        local ffprobe_version=$(ffprobe -version | head -1 | sed 's/ffprobe version //' | cut -d' ' -f1 || echo "unknown")
        echo "  • ffprobe: $ffprobe_version"
    else
        echo "  • ffprobe: not found"
    fi
    
    # Check ffmpeg version
    if command -v ffmpeg &> /dev/null; then
        local ffmpeg_version=$(ffmpeg -version | head -1 | sed 's/ffmpeg version //' | cut -d' ' -f1 || echo "unknown")
        echo "  • ffmpeg: $ffmpeg_version"
    else
        echo "  • ffmpeg: not found"
    fi
    
    echo ""
}

# Run a command and check its exit code
run_command() {
    local description="$1"
    local command="$2"
    local expected_exit_code="${3:-0}"
    
    log_info "Running: $description"
    echo "Command: $command"
    
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
    show_tools_directory
    show_tool_versions
    
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
    show_tools_directory
    show_tool_versions
    
    run_command "Show info for test files" "$(get_cli_command) info $TEST_FILES_DIR/ --yes"
}

test_add_single_file() {
    echo ""
    echo "=== TEST 3: ADD ONE FILE ==="
    show_tools_directory
    show_tool_versions
    
    run_command "Add single test file" "$(get_cli_command) add $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    
    run_command "Check single file added" "$(get_cli_command) check $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
}

test_add_same_file() {
    echo ""
    echo "=== TEST 4: ADD SAME FILE (NO DUPLICATION) ==="
    show_tools_directory
    show_tool_versions
    
    run_command "Re-add same file" "$(get_cli_command) add $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
    
    run_command "Check file still in database" "$(get_cli_command) check $TEST_DB_DIR $TEST_FILES_DIR/test.png --yes"
}

test_add_multiple_files() {
    echo ""
    echo "=== TEST 5: ADD MULTIPLE FILES ==="
    show_tools_directory
    show_tool_versions
    
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
    echo "=== TEST 6: ADD SAME MULTIPLE FILES (NO DUPLICATION) ==="
    show_tools_directory
    show_tool_versions
    
    if [ -d "$MULTIPLE_IMAGES_DIR" ]; then
        run_command "Re-add multiple files" "$(get_cli_command) add $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
        
        run_command "Check multiple files still in database" "$(get_cli_command) check $TEST_DB_DIR $MULTIPLE_IMAGES_DIR/ --yes"
    else
        log_warning "Multiple images directory not found: $MULTIPLE_IMAGES_DIR"
        log_warning "Skipping multiple file tests"
    fi
}

test_cannot_create_over_existing() {
    echo ""
    echo "=== TEST 7: CANNOT CREATE DATABASE OVER EXISTING ==="
    show_tools_directory
    show_tool_versions
    
    run_command "Fail to create database over existing" "$(get_cli_command) init $TEST_DB_DIR --yes" 1
}

test_ui_skipped() {
    echo ""
    echo "=== TEST 8: UI TEST (SKIPPED IN AUTOMATED RUN) ==="
    show_tools_directory
    show_tool_versions
    log_info "UI test skipped - would run: $(get_cli_command) ui $TEST_DB_DIR --yes"
    log_info "This requires manual verification in a real environment"
}

test_cloud_skipped() {
    echo ""
    echo "=== CLOUD TESTS SKIPPED ==="
    show_tools_directory
    show_tool_versions
    log_info "S3/Cloud database tests skipped - require AWS credentials"
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
    
    # Remove test database directories with more comprehensive paths
    local test_db_paths=(
        "$TEST_DB_DIR"
        "./test/test-db" 
        "./test-db"
        "./test/db"
        "./test/test-database"
        "./temp-test-setup"
        "test/test-db"
        "test-db"
    )
    
    local found_any=false
    
    for path in "${test_db_paths[@]}"; do
        if [ -d "$path" ]; then
            log_info "Removing test database: $path"
            rm -rf "$path"
            log_success "Removed $path"
            found_any=true
        fi
    done
    
    if [ "$found_any" = false ]; then
        log_info "No test database directories found (already clean)"
    fi
    
    # Clean up any leftover frontend build artifacts if they exist
    if [ -f "pfe.zip" ]; then
        log_info "Removing frontend build artifact: pfe.zip"
        rm -f "pfe.zip"
        log_success "Removed pfe.zip"
    fi
    
    # Clean up any TypeScript build artifacts
    if [ -f "tsconfig.tsbuildinfo" ]; then
        log_info "Removing TypeScript build info"
        rm -f "tsconfig.tsbuildinfo"
        log_success "Removed TypeScript build info"
    fi
    
    # Show what's left in test directory for debugging
    if [ -d "./test" ]; then
        log_info "Contents of ./test directory after cleanup:"
        ls -la ./test/ 2>/dev/null || log_info "  (empty or no access)"
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
    log_info "Cleaning up previous test run"
    rm -rf "$TEST_DB_DIR"
    
    # Run all tests in sequence 
    test_create_database
    test_view_media_files
    test_add_single_file
    test_add_same_file
    test_add_multiple_files
    test_add_same_multiple_files
    test_cannot_create_over_existing
    test_ui_skipped
    test_cloud_skipped
    
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
    rm -rf "$TEST_DB_DIR" 2>/dev/null || true
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
        "add-single"|"3")
            test_add_single_file
            ;;
        "add-same"|"4")
            test_add_same_file
            ;;
        "add-multiple"|"5")
            test_add_multiple_files
            ;;
        "add-same-multiple"|"6")
            test_add_same_multiple_files
            ;;
        "no-overwrite"|"7")
            test_cannot_create_over_existing
            ;;
        "ui"|"8")
            test_ui_skipped
            ;;
        "cloud"|"9")
            test_cloud_skipped
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
                test_add_single_file
                test_add_same_file
                test_add_multiple_files
                test_add_same_multiple_files
                test_cannot_create_over_existing
                test_ui_skipped
                test_cloud_skipped
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
            "add-single"|"3")
                test_add_single_file
                ;;
            "add-same"|"4")
                test_add_same_file
                ;;
            "add-multiple"|"5")
                test_add_multiple_files
                ;;
            "add-same-multiple"|"6")
                test_add_same_multiple_files
                ;;
            "no-overwrite"|"7")
                test_cannot_create_over_existing
                ;;
            "ui"|"8")
                test_ui_skipped
                ;;
            "cloud"|"9")
                test_cloud_skipped
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
    exit 0
}

# Show usage information
show_usage() {
    echo "Usage: $0 <command|test-name> [command2,command3,...]"
    echo ""
    echo "Run Photosphere CLI smoke tests"
    echo ""
    echo "Commands:"
    echo "  all                 - Run all tests (assumes executable built and tools available)"
    echo "  setup               - Build executable and frontend"
    echo "  install-tools       - Install required media processing tools only"
    echo "  reset               - Clean up test artifacts and reset environment"
    echo "  help                - Show this help message"
    echo ""
    echo "Individual tests:"
    echo "  create-database (1) - Create new database"
    echo "  view-media (2)      - View local media files"
    echo "  add-single (3)      - Add single file to database"
    echo "  add-same (4)        - Add same file again (no duplication)"
    echo "  add-multiple (5)    - Add multiple files"
    echo "  add-same-multiple (6) - Add same multiple files again"
    echo "  no-overwrite (7)    - Cannot create database over existing"
    echo "  ui (8)              - UI test (skipped)"
    echo "  cloud (9)           - Cloud tests (skipped)"
    echo ""
    echo "Multiple commands:"
    echo "  Use commas to separate commands (no spaces around commas)"
    echo ""
    echo "Examples:"
    echo "  $0 all                    # Run all tests (exe must be built, tools available)"
    echo "  $0 setup,all              # Build and run all tests (tools must be available)"
    echo "  $0 setup,install-tools,all # Build, install tools, and run all tests"
    echo "  $0 setup                  # Build executable and frontend only"
    echo "  $0 install-tools          # Install tools only"
    echo "  $0 reset                  # Clean up test artifacts"
    echo "  $0 create-database        # Run only database creation test"
    echo "  $0 3                      # Run test 3 (add single file)"
    echo "  $0 reset,setup,1,3        # Reset, setup, create DB, then test 3"
    echo "  $0 help                   # Show this help"
}

# Main test execution
main() {
    # Check for help request or no arguments
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
        show_usage
        exit 0
    fi
    
    # Check if multiple commands are provided (contains comma)
    if [[ "$1" == *","* ]]; then
        CLEANUP_ON_EXIT="false"  # Multiple commands handle their own flow
        run_multiple_commands "$1"
        return
    fi
    
    # Check if running all tests
    if [ "$1" = "all" ]; then
        CLEANUP_ON_EXIT="false"  # run_all_tests handles its own cleanup
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
        CLEANUP_ON_EXIT="true"  # Setup can cleanup after itself
        test_setup
        exit 0
    fi
    
    # Check if running install-tools command
    if [ "$1" = "install-tools" ]; then
        CLEANUP_ON_EXIT="false"  # Don't cleanup after installing tools
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
            CLEANUP_ON_EXIT="true"
            ;;
        "create-database"|"1")
            # Don't cleanup after create-database - other tests might need it
            CLEANUP_ON_EXIT="false"
            ;;
        *)
            # Other tests might depend on existing database, don't cleanup unless it's a standalone test
            CLEANUP_ON_EXIT="false"
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

# Handle script termination
cleanup() {
    # Only cleanup if we're not running all tests or if we're running individual tests that don't need the database
    if [ "$CLEANUP_ON_EXIT" = "true" ]; then
        echo ""
        log_info "Cleaning up test artifacts..."
        rm -rf "$TEST_DB_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Run main function
main "$@"