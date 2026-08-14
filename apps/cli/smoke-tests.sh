#!/bin/bash

# Photosphere CLI Smoke Tests
# This script runs smoke tests to verify basic CLI functionality

# Absolute path to this script's directory, resolved before any cd takes place.
SMOKE_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# On Windows (msys/cygwin), pwd returns a POSIX path (/d/a/...) that native .exe binaries
# cannot resolve. pwd -W returns a Windows-style path (D:/a/...) that both bash and .exe understand.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    _CLI_ABS_DIR="$(cd "$(dirname "$0")" && pwd -W)"
else
    _CLI_ABS_DIR="$SMOKE_TESTS_DIR"
fi

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

# Per-test temporary directories, the same allocator every other suite in this repository uses.
source "$_CLI_ABS_DIR/../../scripts/lib/allocate-test-temp-dir.sh"

# Starting and stopping background processes: the tree walk the traps below use to take a batch
# subshell together with the CLI processes underneath it. Shared with the desktop and mobile suites
# so there is one implementation rather than a copy per caller.
#
# No leak check here, unlike the desktop and mobile suites. Theirs works by scoping to the process
# groups their own launches recorded, and nothing in this suite launches through
# launch_in_process_group: a CLI test starts `psi` directly, in its own batch subshell. There is
# nothing to scope to, so a check here would be one that can never fire. What stops this suite
# leaking is the tree kill in the traps below.
source "$_CLI_ABS_DIR/../../scripts/lib/process-control.sh"

# The per-test timeout every suite in this repository shares, and the reporting that goes with it.
source "$_CLI_ABS_DIR/../../scripts/lib/test-timeout.sh"

# How wide the pool runs: read from the machine, or handed down by a caller that is running other
# suites beside this one.
source "$_CLI_ABS_DIR/../../scripts/lib/test-concurrency.sh"

# The rolling pool the tests are scheduled through, shared with the desktop suite so there is one
# scheduler rather than a copy per suite.
source "$_CLI_ABS_DIR/../../scripts/lib/test-pool.sh"

# Test configuration
#
# The suite root, which holds the build output and whatever the setup and reset commands work on.
# It is NOT where a test runs: each test is given a uniquely named directory of its own by
# allocate_isolated_test_dir below, so two runs out of one checkout cannot collide.
#
# Exported, and this is load-bearing rather than tidiness. The CLI is a child process, so a
# TEST_TMP_DIR that is merely assigned is invisible to it: getProcessTmpDir() then falls back to the
# system temp dir and every CLI process on the machine shares /tmp/photosphere. This suite runs
# `hash-cache clear` four times, which deletes that directory outright, and it took out the log
# directory of a suite running alongside in the middle of writing to it.
export TEST_TMP_DIR="${TEST_TMP_DIR:-$_CLI_ABS_DIR/test/tmp}"
TEST_DB_DIR="$TEST_TMP_DIR/shared/test-db"
TEST_FILES_DIR="../../test"
MULTIPLE_IMAGES_DIR="../../test/multiple-files"
DUPLICATE_IMAGES_DIR="../../test/duplicate-images"

# Isolate the vault and config so tests don't pollute the user's real data.
export PHOTOSPHERE_VAULT_DIR="${TEST_TMP_DIR}/vault"
export PHOTOSPHERE_CONFIG_DIR="${TEST_TMP_DIR}/config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Use built binary instead of bun run start (set by --binary)
USE_BINARY=false

# Set by --source: run against the TypeScript rather than the compiled binaries.
#
# A full run builds the binaries and uses them, because that is what ships and because a psi
# invocation costs about 0.10s less from the binary than through `bun run start`, which is roughly
# 41s of work across the suite's 412 invocations. --source is the way back to the TypeScript, so that
# path is not left to rot.
USE_SOURCE=false

# Execution mode: "parallel" (default) or "sequential"
EXECUTION_MODE=parallel

# How many tests the pool keeps in flight. From the machine, or from PHOTOSPHERE_TEST_PARALLEL when a
# caller running other suites beside this one has said what share it gets. 5 is what this suite ran at
# before it asked, and is what a host that reports no core count still gets. An explicit --parallel N
# beats both.
PARALLEL_N="$(resolve_test_parallel 5)" || exit 1

# Record start time for total duration reporting
SMOKE_TESTS_START_TIME=$SECONDS

# Exit code a test uses to say it did not run its body, so the runner reports it as skipped rather
# than as a pass. A skip is counted and printed separately and never folded into the pass total,
# because a suite that reports coverage it did not perform is worse than one that reports a failure.
# 77 is the conventional skip code and is the same value apps/smoke-tests/lib/runner.sh uses, so the
# two suites do not disagree about what it means.
export TEST_SKIPPED_EXIT_CODE=77

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

# Track log files for failed tests so we can dump them after the summary
FAILED_TEST_LOGS=()

# Trap to show summary on exit (including failures)
#
# Also stops anything still running. This used to print and nothing else, so an exit that was not a
# clean end of the run (a failure part way through a batch, or the parallel runner's SIGTERM routed
# here by handle_interrupt) left the batch subshells and every CLI process under them alive and
# reparented to init. A suite must not outlive itself.
cleanup_and_show_summary() {
    local exit_code=$?
    local job_pid
    for job_pid in $(jobs -p); do
        kill_process_tree "$job_pid"
    done

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

# Handle Ctrl-C: kill all background jobs and exit immediately.
#
# Each background job is a batch subshell, and the CLI processes doing the actual work are its
# children, not the job itself. Signalling only the job left every one of those children running and
# reparented to init, which is the leak this suite contributed. kill_process_tree takes the whole
# tree, and takes it before anything dies, while the parent links are still there to follow.
handle_interrupt() {
    echo ""
    echo "Interrupted."
    local job_pid
    for job_pid in $(jobs -p); do
        kill_process_tree "$job_pid"
    done
    exit 130
}

# TERM as well as INT: the parallel runner enforces its per-suite timeout with SIGTERM, and with no
# handler for it this script died leaving its batch subshells and the CLI processes they had started
# running.
trap handle_interrupt INT
trap handle_interrupt TERM

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

#
# Builds the three executables the tests run: psi, mk and bdb.
#
# Must be called with the CLI directory as the working directory, because each build is invoked
# through the package it belongs to.
#
build_cli_binaries() {
    local platform=$(detect_platform)
    local arch=$(detect_architecture)

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

    build_cli_binaries

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

#
# Allocates the directory one test runs in. It is handed down as TEST_TMP_DIR, which
# smoke-tests/lib/common.sh also points PHOTOSPHERE_TMP_DIR at so the psi processes the test starts
# write their own temporary files inside it too.
#
# The name comes from the allocator rather than from the test's own directory name, so two runs out
# of one checkout cannot be handed the same path. That is the whole point: the fixed
# <suite root>/<test name> this replaced is shared by every concurrent run.
# Usage: allocate_isolated_test_dir <test_dir_name>
#
allocate_isolated_test_dir() {
    photosphere_test_temp_dir "$1"
}

# Run a single test script sequentially; redirect all script output to its log file.
run_one() {
    local test_sh="$1"
    local dir num name log_file dir_name
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    dir_name="$(basename "$dir")"
    export TEST_TMP_DIR="$(allocate_isolated_test_dir "$dir_name")"
    log_file="$TEST_TMP_DIR/test-run.log"
    printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
    local test_start=$SECONDS
    local test_status=0
    run_test_with_timeout "$PHOTOSPHERE_PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1 || test_status=$?
    if test_timed_out "$test_status"; then
        report_test_timeout "$name" "$PHOTOSPHERE_PER_TEST_TIMEOUT" "$log_file"
        FAILED_TEST_LOGS+=("$log_file")
        return 1
    fi
    if [ "$test_status" -eq "$TEST_SKIPPED_EXIT_CODE" ]; then
        local test_duration
        test_duration=$(format_duration $((SECONDS - test_start)))
        printf "${BLUE}SKIP${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
        return "$TEST_SKIPPED_EXIT_CODE"
    fi
    if [ "$test_status" -eq 0 ]; then
        local test_duration
        test_duration=$(format_duration $((SECONDS - test_start)))
        printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
        return 0
    else
        local test_duration
        test_duration=$(format_duration $((SECONDS - test_start)))
        printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
        FAILED_TEST_LOGS+=("$log_file")
        return 1
    fi
}

# Run each script one at a time with run_one; accumulate counts and call print_summary.
run_sequential() {
    local pass=0
    local fail=0
    local skip=0
    local one_status
    for test_sh in "$@"; do
        one_status=0
        run_one "$test_sh" || one_status=$?
        if [ "$one_status" -eq 0 ]; then
            pass=$((pass + 1))
        elif [ "$one_status" -eq "$TEST_SKIPPED_EXIT_CODE" ]; then
            skip=$((skip + 1))
        else
            fail=$((fail + 1))
        fi
    done
    print_failed_logs
    print_summary "$pass" "$fail" "$skip"
    return $((fail > 0 ? 1 : 0))
}

#
# Starts one test in the background for run_test_pool, which takes its pid from TEST_POOL_JOB_PID and
# hands the directory the test was told to run in back to the reporter through TEST_POOL_JOB_CONTEXT.
#
# The directory is allocated out here rather than inside the job, because the reporter needs it to
# find the test's log and its duration once the job has gone, and it is no longer derivable from the
# test's name: every test gets a uniquely named directory, which is the point.
# Usage: start_cli_pool_job <test.sh>
#
start_cli_pool_job() {
    local test_sh="$1"
    local dir num name dir_name test_dir log_file
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    dir_name="$(basename "$dir")"
    test_dir="$(allocate_isolated_test_dir "$dir_name")"
    log_file="$test_dir/test-run.log"
    printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
    # Started here in the runner's own shell, never through a command substitution: a job started
    # inside one is the subshell's child, so this shell could not `wait` for it and would have no
    # exit status to report.
    (
        local_start=$SECONDS
        TEST_TMP_DIR="$test_dir" run_test_with_timeout "$PHOTOSPHERE_PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1
        local_exit=$?

        # Retry once, and only when Bun itself crashed rather than a test failing an assertion.
        #
        # Bun 1.3.14 intermittently dies inside its own runtime while the CLI is using worker
        # threads, printing "Bun has crashed. This indicates a bug in Bun, not your code" and a
        # panic line, then killing the process with SIGILL or SIGSEGV. It has hit six different
        # tests across three different commands at roughly one run in six, so it is neither any one
        # test nor this repository's code, and there is no newer Bun to move to.
        #
        # The match is on that crash signature in the test's own log, not on the exit code: the
        # crash happens to a `bun run` child inside the test, which the test catches and reports as
        # an ordinary failure exiting 1, so an exit code cannot tell the two apart. An assertion
        # failure leaves no panic line and is never retried, so a real regression still fails the
        # run exactly as it did before.
        #
        # The retry is announced rather than silent, and the crashed run's log is kept alongside as
        # .signal-death. A suite that quietly re-runs things until they pass is worse than one that
        # fails, because it hides a rising failure rate.
        if [ "$local_exit" -ne 0 ] && grep -qE "Bun has crashed|panic: |terminated by signal SIG(ILL|SEGV|BUS|ABRT)" "$log_file" 2>/dev/null; then
            printf "${YELLOW}RETRY${NC} %2s  %s hit a Bun runtime crash (not an assertion), retrying once\n" "$num" "$name"
            mv "$log_file" "$log_file.signal-death" 2>/dev/null || true
            # The retry gets a freshly allocated directory rather than the crashed run's
            # directory emptied and reused, so the crashed run's state is still there to
            # look at and the retry cannot inherit half-written files from it.
            retry_dir="$(allocate_isolated_test_dir "$dir_name")"
            TEST_TMP_DIR="$retry_dir" run_test_with_timeout "$PHOTOSPHERE_PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1
            local_exit=$?
        fi

        echo $((SECONDS - local_start)) > "$test_dir/test-duration.txt"
        exit $local_exit
    ) &
    TEST_POOL_JOB_PID="$!"
    TEST_POOL_JOB_CONTEXT="$test_dir"
}

#
# Reports a finished test and counts it, taking the exit status the job left behind.
#
# Three outcomes rather than two, which is why the pool library leaves the counting here: a skip is
# counted and printed on its own and is never folded into the pass total. The counters are
# run_parallel's own `pass`, `fail` and `skip`, reached the way bash reaches a caller's variables.
# Usage: report_cli_pool_result <status> <test.sh> <test_dir>
#
report_cli_pool_result() {
    local status="$1"
    local test_sh="$2"
    local test_dir="$3"
    local num name log_file test_duration
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$test_dir/test-run.log"
    test_duration=$(format_duration "$(cat "$test_dir/test-duration.txt" 2>/dev/null || echo 0)")

    if [ "$status" -eq "$TEST_SKIPPED_EXIT_CODE" ]; then
        printf "${BLUE}SKIP${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
        skip=$((skip + 1))
    elif [ "$status" -eq 0 ]; then
        printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
        pass=$((pass + 1))
    elif test_timed_out "$status"; then
        # The subshell exits with what run_test_with_timeout returned, so a test that ran out
        # of time still arrives here carrying the timeout code and is named as one rather than
        # being folded in with the assertion failures.
        report_test_timeout "$name" "$PHOTOSPHERE_PER_TEST_TIMEOUT" "$log_file"
        FAILED_TEST_LOGS+=("$log_file")
        fail=$((fail + 1))
    else
        printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
        FAILED_TEST_LOGS+=("$log_file")
        fail=$((fail + 1))
    fi
    return 0
}

# Run scripts in a rolling pool of N; accumulate counts and call print_summary.
run_parallel() {
    local parallel_n="$1"
    shift
    local pass=0
    local fail=0
    local skip=0

    run_test_pool "$parallel_n" start_cli_pool_job report_cli_pool_result "$@"

    print_failed_logs
    print_summary "$pass" "$fail" "$skip"
    return $((fail > 0 ? 1 : 0))
}

# Print final pass/fail summary banner.
print_summary() {
    local pass="$1"
    local fail="$2"
    local skip="${3:-0}"
    local total=$((pass + fail + skip))
    local elapsed=$((SECONDS - SMOKE_TESTS_START_TIME))
    local minutes=$((elapsed / 60))
    local secs=$((elapsed % 60))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d tests passed${NC}\n" "$pass"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$total"
    fi
    # Reported on its own line and never folded into the pass count, so a run that skipped
    # something can never read as having covered it.
    if ((skip > 0)); then
        printf "${BLUE}%d test(s) skipped${NC}\n" "$skip"
    fi
    if ((minutes > 0)); then
        printf "Duration: %dm %ds\n" "$minutes" "$secs"
    else
        printf "Duration: %ds\n" "$secs"
    fi
}

# Print the log output for every failed test.
print_failed_logs() {
    if [ ${#FAILED_TEST_LOGS[@]} -eq 0 ]; then
        return
    fi
    echo ""
    echo "============================================================================"
    echo "FAILED TEST OUTPUT"
    echo "============================================================================"
    for log_file in "${FAILED_TEST_LOGS[@]}"; do
        # The log sits in the directory allocated for the test, and that directory is named after
        # the test with a unique suffix, so its own name is the label.
        local test_dir_name
        test_dir_name=$(basename "$(dirname "$log_file")")
        echo ""
        echo "---------- $test_dir_name ($log_file) ----------"
        cat "$log_file"
        echo "---------- end $test_dir_name ----------"
    done
}

# Discover all test scripts under smoke-tests/ in sorted order
discover_tests() {
    find smoke-tests -name "test.sh" | sort -V
}

#
# Builds the five-file database this run's tests copy, and points them at it.
#
# 18 tests each built the identical five-file database before they began, at about 5 seconds a time,
# which is 90 seconds of the suite's work spent producing 18 copies of a 7.5MB directory that takes
# under a second to copy.
#
# The directory comes from the allocator rather than being a path named here, because two runs out of
# one checkout must not share it.
#
# A fixture that fails to build fails the run. The alternative is 18 tests quietly falling back to
# building it themselves, which is the cost this removes, arriving as an unexplained slowdown rather
# than as an error.
#
build_shared_fixtures() {
    local fixture_dir
    fixture_dir="$(allocate_isolated_test_dir "fixture-db-5-files")"
    log_info "Building the shared five-file database in $fixture_dir"
    # In a subshell with its own TEST_TMP_DIR, so the UUID counter the build leaves behind lands
    # beside the database rather than in the suite root, and so this run's own TEST_TMP_DIR is not
    # changed by building it.
    if ! (
        export TEST_TMP_DIR="$fixture_dir"
        export PHOTOSPHERE_TMP_DIR="$fixture_dir"
        bash "$SMOKE_TESTS_DIR/smoke-tests/lib/build-5-file-fixture.sh" > "$fixture_dir/build.log" 2>&1
    ); then
        log_error "Failed to build the shared five-file database. Output:"
        cat "$fixture_dir/build.log"
        return 1
    fi
    export PHOTOSPHERE_SMOKE_FIXTURE_5_FILES="$fixture_dir"
    log_success "Built the shared five-file database"
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

    # The tests run against what ships. Building all three takes about 0.8s, and every psi invocation
    # after that is about 0.10s cheaper than it is through `bun run start`.
    if [ "$USE_SOURCE" = "true" ]; then
        log_info "Running against the TypeScript sources (--source)"
    else
        USE_BINARY=true
        build_cli_binaries
    fi
    # Exported so the test scripts see it: smoke-tests/lib/common.sh reads it to decide which command
    # each of psi, mk and bdb is.
    export USE_BINARY

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
    invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" || {
        log_warning "Failed to clear cache, continuing anyway..."
    }

    # Check tools first
    check_tools

    # Built once here and copied by every test that needs it.
    build_shared_fixtures || exit 1

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

    # A ceiling on the whole run, on top of the one every test already gets. The per-test cap cannot
    # catch everything: on Git Bash there is no timeout(1), so it falls back to killing the test's
    # process tree and waiting on it, and a kill that does not take leaves that wait blocked for good.
    # This suite normally takes 15 minutes on windows-latest and has twice run past 27 and 40, each
    # time until the GitHub job timeout killed the job, which discards the job's log rather than
    # writing it. Failing from in here ends the step normally instead, so everything printed so far
    # survives, including the RUN line of whichever test never reported back.
    start_suite_watchdog "cli-smoke-tests" "$PHOTOSPHERE_SUITE_TIMEOUT"

    echo ""
    if [ "${EXECUTION_MODE:-parallel}" = "sequential" ]; then
        log_info "Running ${#all_scripts[@]} tests sequentially"
        run_sequential "${all_scripts[@]}"
    else
        # The width is said out loud because it is no longer a constant in this file: it comes from
        # the machine, from PHOTOSPHERE_TEST_PARALLEL or from --parallel, and a run that is slower
        # than expected should not need the source read to find out which.
        log_info "Running ${#all_scripts[@]} tests, up to $PARALLEL_N at a time"
        run_parallel "$PARALLEL_N" "${all_scripts[@]}"
    fi
    local exit_code=$?
    stop_suite_watchdog

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
    invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" || {
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
    echo "  -b, --binary          - Run tests using the built executable. A full run does this anyway;"
    echo "                          this is how a single test does it"
    echo "  --source              - Run against the TypeScript sources instead of the built executables"
    echo "  -t, --tmp-dir <dir>   - Use <dir> for test databases (default: ./test/tmp)."
    echo "  --sequential          - Run independent tests sequentially instead of in parallel"
    echo "  --parallel [N]        - Run independent tests in a rolling pool of N. The default comes"
    echo "                          from the core count and is $PARALLEL_N on this machine"
    echo "  -h, --help            - Show this help message"
    echo ""
    echo "Environment:"
    echo "  PHOTOSPHERE_TEST_PARALLEL - How many tests to run at once, in place of the core count."
    echo "                          Set by scripts/test-everything-parallel.sh so the lanes of one"
    echo "                          run share the machine. A value that is not a positive integer is"
    echo "                          refused. --parallel N beats it."
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
    echo "  $0 --parallel 3              # Run 3 tests at a time"
    echo "  $0 --parallel 10             # Run 10 tests at a time"
    echo "  $0 --source                  # Run all tests against the TypeScript sources"
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
            --source)
                USE_SOURCE=true
                USE_BINARY=false
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

    # Exported so the test scripts see it, which is what makes --binary mean anything for a single
    # test: smoke-tests/lib/common.sh reads it to decide which command each of psi, mk and bdb is,
    # and a variable that is only assigned here is invisible to them.
    export USE_BINARY

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
            invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" || {
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
    invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" || {
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
