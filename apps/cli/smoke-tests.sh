#!/bin/bash

# Photosphere CLI Smoke Tests
# Based on test plan from photosphere-wiki/Test-plan-from-repo.md
# This script runs smoke tests to verify basic CLI functionality

# Absolute path to this script's directory, resolved before any cd takes place.
SMOKE_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

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
# Override TEST_TMP_DIR to run tests in parallel (e.g. TEST_TMP_DIR=./test/tmp-$$ ./smoke-tests.sh)
TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp}"
TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-images"
DUPLICATE_IMAGES_DIR="../../test/duplicate-images"

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Use built binary instead of bun run start (set by --binary)
USE_BINARY=false

# Execution mode: "parallel" (default) or "sequential"
EXECUTION_MODE=parallel

# Batch size for parallel execution (default 5)
PARALLEL_N=5

# Record start time for total duration reporting
SMOKE_TESTS_START_TIME=$SECONDS

# Get test directory path for a given test number
get_test_dir() {
    local test_number="$1"
    echo "$TEST_TMP_DIR/$test_number"
}

# Read the DESCRIPTION field from a test script.
get_test_description_for_script() {
    local test_sh="$1"
    grep -m1 '^DESCRIPTION=' "$test_sh" | cut -d= -f2- | tr -d '"'
}

# Get test index by name (returns numeric prefix, or 0 if not found).
get_test_index_by_name() {
    local name="$1"
    while IFS= read -r test_sh; do
        if [ "$(test_name "$test_sh")" = "$name" ]; then
            test_number "$test_sh"
            return 0
        fi
    done < <(discover_tests)
    echo "0"
    return 1
}

# Get total number of tests.
get_test_count() {
    discover_tests | wc -l | tr -d ' '
}

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Trap to show summary on exit (including failures)
cleanup_and_show_summary() {
    local exit_code=$?
    echo ""
    echo "============================================================================"
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ ALL SMOKE TESTS PASSED ✓✓✓${NC}"
    else
        echo -e "${RED}✗✗✗ SMOKE TESTS FAILED ✗✗✗${NC}"
    fi
    echo "============================================================================"

    exit $exit_code
}

trap cleanup_and_show_summary EXIT

# Helper functions shared with check-tools.sh
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

# Unified command invocation (needed by test_setup and check_tools)
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

    local command_output=""
    local actual_exit_code=0

    local env_prefix="NODE_ENV=testing "
    local full_command="$env_prefix$command"

    if [ -n "$output_var_name" ]; then
        command_output=$(eval "$full_command" 2>&1)
        actual_exit_code=$?
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        echo "$command_output"
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
        eval "$output_var_name=\"\$command_output\""
    else
        echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
        eval "$full_command"
        actual_exit_code=$?
        echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
    fi

    if [ $actual_exit_code -eq $expected_exit_code ]; then
        if [ $expected_exit_code -eq 0 ]; then
            log_success "$description"
        else
            log_success "$description (expected failure with exit code $actual_exit_code)"
        fi
        return 0
    else
        if [ $expected_exit_code -eq 0 ]; then
            log_error "$description (exit code: $actual_exit_code)"
        else
            log_error "$description (expected failure but command succeeded)"
        fi
        exit 1
    fi
}

# Individual test functions (remain inline — not tests, just setup)
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
    rm -rf "$TEST_TMP_DIR"

    # Ensure tmp directory exists
    mkdir -p "$TEST_TMP_DIR"

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

    log_info "Building mk CLI executable for platform: $platform ($arch)"
    cd ../mk-cli
    case "$platform" in
        "linux")
            invoke_command "Build mk Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build mk macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build mk macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build mk Windows executable" "bun run build-win"
            ;;
    esac
    cd ../cli

    log_info "Building bdb CLI executable for platform: $platform ($arch)"
    cd ../bdb-cli
    case "$platform" in
        "linux")
            invoke_command "Build bdb Linux executable" "bun run build-linux"
            ;;
        "mac")
            if [ "$arch" = "arm64" ]; then
                invoke_command "Build bdb macOS ARM64 executable" "bun run build-mac-arm64"
            else
                invoke_command "Build bdb macOS x64 executable" "bun run build-mac-x64"
            fi
            ;;
        "win")
            invoke_command "Build bdb Windows executable" "bun run build-win"
            ;;
    esac
    cd ../cli

    TESTS_PASSED=$((TESTS_PASSED + 1))
}

check_tools() {
    # shellcheck source=./check-tools.sh
    source "$SMOKE_TESTS_DIR/check-tools.sh"
    run_check_tools
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
    local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
    if [ -f "$UUID_COUNTER_FILE" ]; then
        log_info "Resetting test UUID counter"
        rm -f "$UUID_COUNTER_FILE"
        log_success "Removed UUID counter file"
    else
        log_info "UUID counter file not found (already clean)"
    fi
    
    # Remove the specific test database directory
    if [ -d "$TEST_TMP_DIR" ]; then
        log_info "Removing all test databases: $TEST_TMP_DIR"
        rm -rf "$TEST_TMP_DIR"
        log_success "Removed $TEST_TMP_DIR"
    else
        log_info "Test tmp directory not found (already clean): $TEST_TMP_DIR"
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

# Extract the numeric prefix from a test script path (e.g. smoke-tests/27-v2-readonly/test.sh -> 27)
test_number() {
    local test_sh="$1"
    basename "$(dirname "$test_sh")" | grep -oE '^[0-9]+'
}

# Extract the name portion from a test script path (e.g. smoke-tests/27-v2-readonly/test.sh -> v2-readonly)
test_name() {
    local test_sh="$1"
    basename "$(dirname "$test_sh")" | sed 's/^[0-9]*-//'
}

# Format a duration in seconds as Xm Ys or Xs.
format_duration() {
    local elapsed="$1"
    local minutes=$((elapsed / 60))
    local secs=$((elapsed % 60))
    if ((minutes > 0)); then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# Run a single test script sequentially; redirect all script output to its log file.
run_one() {
    local test_sh="$1"
    local dir num name log_file dir_name
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$dir/tmp/test-run.log"
    dir_name="$(basename "$dir")"
    mkdir -p "$dir/tmp"
    export ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/${dir_name}"
    printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
    local test_start=$SECONDS
    if timeout 300 bash "$test_sh" >"$log_file" 2>&1; then
        local test_duration
        test_duration=$(format_duration $((SECONDS - test_start)))
        printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
        return 0
    else
        local test_duration
        test_duration=$(format_duration $((SECONDS - test_start)))
        printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
        return 1
    fi
}

# Run each script one at a time with run_one; accumulate counts and call print_summary.
run_sequential() {
    local pass=0
    local fail=0
    for test_sh in "$@"; do
        if run_one "$test_sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

# Run scripts in parallel batches of N; accumulate counts and call print_summary.
run_parallel() {
    local parallel_n="$1"
    shift
    local tests=("$@")
    local pass=0
    local fail=0
    local total="${#tests[@]}"
    local i=0

    while ((i < total)); do
        local batch_tests=()
        local batch_pids=()
        local j=0
        while ((j < parallel_n && i < total)); do
            batch_tests+=("${tests[i]}")
            i=$((i + 1))
            j=$((j + 1))
        done

        for test_sh in "${batch_tests[@]}"; do
            local dir log_file num name dir_name
            dir="$(dirname "$test_sh")"
            num="$(test_number "$test_sh")"
            name="$(test_name "$test_sh")"
            dir_name="$(basename "$dir")"
            log_file="$dir/tmp/test-run.log"
            mkdir -p "$dir/tmp"
            printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
            (
                local_start=$SECONDS
                ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/${dir_name}" timeout 300 bash "$test_sh" >"$log_file" 2>&1
                local_exit=$?
                echo $((SECONDS - local_start)) > "$dir/tmp/test-duration.txt"
                exit $local_exit
            ) &
            batch_pids+=($!)
        done

        local k=0
        for pid in "${batch_pids[@]}"; do
            local test_sh num name
            test_sh="${batch_tests[$k]}"
            num="$(test_number "$test_sh")"
            name="$(test_name "$test_sh")"
            local duration_file
            duration_file="$(dirname "$test_sh")/tmp/test-duration.txt"
            local test_duration
            if wait "$pid"; then
                test_duration=$(format_duration "$(cat "$duration_file" 2>/dev/null || echo 0)")
                printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
                pass=$((pass + 1))
            else
                test_duration=$(format_duration "$(cat "$duration_file" 2>/dev/null || echo 0)")
                printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s/tmp/test-run.log)\n" "$num" "$name" "$test_duration" "$(dirname "$test_sh")"
                fail=$((fail + 1))
            fi
            k=$((k + 1))
        done
    done

    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

# Print final pass/fail summary banner.
print_summary() {
    local pass="$1"
    local fail="$2"
    local total=$((pass + fail))
    local elapsed=$((SECONDS - SMOKE_TESTS_START_TIME))
    local minutes=$((elapsed / 60))
    local secs=$((elapsed % 60))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d tests passed${NC}\n" "$total"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$total"
    fi
    if ((minutes > 0)); then
        printf "Duration: %dm %ds\n" "$minutes" "$secs"
    else
        printf "Duration: %ds\n" "$secs"
    fi
}

# Discover all test scripts under smoke-tests/ in sorted order
discover_tests() {
    find smoke-tests -name "test.sh" | sort -V
}

# Map a test number to its individual script path.
get_script_for_test() {
    local test_number="$1"
    local script
    script=$(find smoke-tests -maxdepth 2 -name "test.sh" | sort -V | grep -E "smoke-tests/${test_number}-" | head -1)
    echo "$script"
}


run_all_tests() {
    echo "======================================"
    echo "Photosphere CLI Smoke Tests"
    echo "======================================"

    log_info "Changing to CLI directory"
    cd "$(dirname "$0")"

    # Reset environment
    log_info "Resetting testing environment"
    if [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
        log_success "Removed existing test databases"
    fi

    # Reset UUID counter
    local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
    if [ -f "$UUID_COUNTER_FILE" ]; then
        rm -f "$UUID_COUNTER_FILE"
    fi

    # Clear local cache
    log_info "Clearing local cache before running tests"
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }

    # Check tools first
    check_tools

    # Collect all scripts (excluding keychain tests)
    local all_scripts=()
    while IFS= read -r script_path; do
        local dir_name
        dir_name=$(basename "$(dirname "$script_path")")
        if [[ "$dir_name" == *keychain* ]]; then
            continue
        fi
        all_scripts+=("$script_path")
    done < <(discover_tests)

    echo ""
    if [ "${EXECUTION_MODE:-parallel}" = "sequential" ]; then
        log_info "Running ${#all_scripts[@]} tests sequentially"
        run_sequential "${all_scripts[@]}"
    else
        log_info "Running ${#all_scripts[@]} tests in parallel (batch size ${PARALLEL_N:-5})"
        run_parallel "${PARALLEL_N:-5}" "${all_scripts[@]}"
    fi
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        exit $exit_code
    fi
    exit 0
}

# Run a specific test by name or number
run_test() {
    local test_name="$1"
    
    # Handle special commands
    case "$test_name" in
        "all")
            run_all_tests
            return
            ;;
        "reset")
            reset_environment
            return
            ;;
        "setup")
            # This is handled as a command in main(), but keeping here for completeness
            test_setup
            return
            ;;
        "check-tools")
            check_tools
            return
            ;;
    esac
    
    # Check if it's a numeric test index
    local test_number
    if [[ "$test_name" =~ ^[0-9]+$ ]]; then
        test_number="$test_name"
        if [ "$test_number" -lt 1 ] || [ "$test_number" -gt "$(get_test_count)" ]; then
            log_error "Invalid test number: $test_number (must be 1-$(get_test_count))"
            echo ""
            show_usage
            exit 1
        fi
    else
        test_number=$(get_test_index_by_name "$test_name")
        if [ "$test_number" -eq 0 ]; then
            log_error "Unknown test: $test_name"
            echo ""
            show_usage
            exit 1
        fi
    fi

    local script_path
    script_path=$(get_script_for_test "$test_number")
    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        log_error "No script found for test $test_number"
        exit 1
    fi

    if ! run_one "$script_path"; then
        exit 1
    fi
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
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    
    # Check tools first before running any tests
    check_tools
    
    
    local command_number=1
    local total_commands=${#COMMANDS[@]}
    
    for command in "${COMMANDS[@]}"; do
        # Trim whitespace
        command=$(echo "$command" | xargs)
        
        echo ""
        echo "--- Command $command_number/$total_commands: $command ---"

        run_test "$command"
        
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
    
    # Always preserve database for inspection
    echo ""
    log_info "Database preserved for inspection at: $TEST_DB_DIR"
    log_info "To clean up when done: $0 reset"
    
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
    echo "  -b, --binary          - Run tests using the built executable (default: run from code with 'bun run start --')"
    echo "  -t, --tmp-dir <dir>   - Use <dir> for test databases (default: ./test/tmp)."
    echo "  --sequential          - Run independent tests sequentially instead of in parallel"
    echo "  --parallel [N]        - Run independent tests in parallel with batch size N (default: 5)"
    echo "  -h, --help            - Show this help message"
    echo ""
    echo "Commands:"
    echo "  all                 - Run all tests (default if no command given)"
    local test_count=$(get_test_count)
    echo "  to <number>         - Run tests 1 through <number> (1-$test_count)"
    echo "  setup               - Build executable"
    echo "  check-tools         - Check required media processing tools are available"
    echo "  reset               - Clean up test artifacts and reset environment"
    echo "  help                - Show this help message"
    echo ""
    echo "Individual tests:"
    while IFS= read -r test_sh; do
        local test_name num description
        test_name=$(test_name "$test_sh")
        num=$(test_number "$test_sh")
        description=$(get_test_description_for_script "$test_sh")
        printf "  %-25s (%d) - %s\n" "$test_name" "$num" "$description"
    done < <(discover_tests)
    echo ""
    echo "Multiple commands:"
    echo "  Use commas to separate commands (no spaces around commas)"
    echo ""
    echo "Examples:"
    echo "  $0                            # Run all tests in parallel (default)"
    echo "  $0 all                        # Run all tests in parallel"
    echo "  $0 --sequential               # Run all tests sequentially"
    echo "  $0 --parallel 3              # Run in parallel with batch size 3"
    echo "  $0 --parallel 10             # Run in parallel with batch size 10"
    echo "  $0 --binary                  # Run all tests using built executable"
    echo "  $0 to 5                      # Run tests 1-5"
    echo "  $0 setup,all                # Build and run all tests (tools must be available)"
    echo "  $0 setup,check-tools,all    # Build, check tools, and run all tests"
    echo "  $0 setup                     # Build executable only"
    echo "  $0 check-tools               # Check tools only"
    echo "  $0 reset                     # Clean up test artifacts"
    echo "  $0 create-database          # Run only database creation test"
    echo "  $0 3                         # Run test 3 (add single file)"
    echo "  $0 27                        # Run test 27 (v2-readonly) independently"
    echo "  $0 help                      # Show this help"
}

# Main test execution
main() {
    # Parse command line options from entire argument list (options can appear before or after test names)
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b|--binary)
                USE_BINARY=true
                shift
                ;;
            -t|--tmp-dir)
                if [ $# -lt 2 ]; then
                    log_error "Option $1 requires a directory argument"
                    exit 1
                fi
                TEST_TMP_DIR="$2"
                TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
                shift 2
                ;;
            --tmp-dir=*)
                TEST_TMP_DIR="${1#*=}"
                TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
                shift
                ;;
            --sequential)
                EXECUTION_MODE=sequential
                shift
                ;;
            --parallel)
                EXECUTION_MODE=parallel
                if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    PARALLEL_N="$2"
                    shift
                fi
                shift
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                POSITIONAL+=("$1")
                shift
                ;;
        esac
    done
    set -- "${POSITIONAL[@]}"
    
    # Check for help request
    if [ $# -eq 1 ] && [ "$1" = "help" ]; then
        show_usage
        exit 0
    fi
    
    # Default to "all" if no command given
    if [ $# -eq 0 ]; then
        set -- "all"
    fi
    
    # Show binary mode status if enabled
    if [ "$USE_BINARY" = "true" ]; then
        log_info "Using built executable for smoke tests"
    fi

    # Handle "to X" command
    if [ "$1" = "to" ] && [ $# -eq 2 ]; then
        local end_test="$2"
        local max_test=$(get_test_count)
        if [[ "$end_test" =~ ^[0-9]+$ ]] && [ "$end_test" -ge 1 ] && [ "$end_test" -le "$max_test" ]; then
            cd "$(dirname "$0")"
            log_info "Running tests 1 through $end_test"
            log_info "Resetting testing environment"
            if [ -d "$TEST_TMP_DIR" ]; then
                rm -rf "$TEST_TMP_DIR"
                log_success "Removed existing test databases"
            fi

            local UUID_COUNTER_FILE="$TEST_TMP_DIR/photosphere-test-uuid-counter"
            if [ -f "$UUID_COUNTER_FILE" ]; then
                rm -f "$UUID_COUNTER_FILE"
            fi

            log_info "Clearing local cache before running tests"
            invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
                log_warning "Failed to clear cache, continuing anyway..."
            }

            check_tools

            # Run individual scripts for tests 1–end_test sequentially.
            local indep_scripts=()
            declare -A seen_indep
            for ((i=1; i<=end_test; i++)); do
                local script
                script=$(get_script_for_test "$i")
                if [ -n "$script" ] && [ -z "${seen_indep[$script]:-}" ]; then
                    seen_indep["$script"]=1
                    indep_scripts+=("$script")
                fi
            done
            if [ ${#indep_scripts[@]} -gt 0 ]; then
                if ! run_sequential "${indep_scripts[@]}"; then
                    exit 1
                fi
            fi

            exit 0
        else
            log_error "Invalid test number: $end_test (must be 1-$max_test)"
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
    invoke_command "Clear local cache" "$(get_cli_command) clear-cache" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }
    
    
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
    
    exit 0
}

# Run main function
main "$@"
