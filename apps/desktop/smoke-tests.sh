#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Per-test temporary directories. Each test gets a uniquely named directory of its own, outside the
# source tree, in place of the fixed <test>/tmp every run used to share.
source "$REPO_DIR/scripts/lib/allocate-test-temp-dir.sh"

# The leak check, so this run can be held to leaving the machine as it found it. Every app the tests
# launch records its process group in this file, and the check at the end looks at those groups and
# nothing else. Exported, because the launches happen in the test.sh child processes.
source "$REPO_DIR/scripts/lib/process-control.sh"
# The per-test timeout every suite in this repository shares, and the reporting that goes with it.
source "$REPO_DIR/scripts/lib/test-timeout.sh"
# How wide the pool runs: read from the machine, or handed down by a caller that is running other
# suites beside this one.
source "$REPO_DIR/scripts/lib/test-concurrency.sh"
export PHOTOSPHERE_LAUNCHED_GROUPS
PHOTOSPHERE_LAUNCHED_GROUPS="$(mktemp "${TMPDIR:-/tmp}/photosphere-desktop-launches-XXXXXX")"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

USE_BINARY=false

# Hard wall-clock limit per test, from scripts/lib/test-timeout.sh so every suite uses one number.
# Generous because a concurrent Android suite run oversubscribes the machine: an Electron app can be
# slow to reach /ready, and wait_for_ready relaunches once on a timeout (up to two
# DEFAULT_WAIT_TIMEOUT waits), which must fit inside this cap plus the test's own actions. A
# standalone run finishes each test in well under this.
PER_TEST_TIMEOUT="$PHOTOSPHERE_PER_TEST_TIMEOUT"

# Record start time for total duration reporting
SMOKE_TESTS_START_TIME=$SECONDS

# Track log files for failed tests so we can dump them after the summary
FAILED_TEST_LOGS=()

# Handle Ctrl-C: kill all background jobs and exit immediately.
handle_interrupt() {
    echo ""
    echo "Interrupted."
    jobs -p | xargs -r kill -TERM 2>/dev/null
    exit 130
}

trap handle_interrupt INT

discover_tests() {
    if [[ ! -d "$SCRIPT_DIR/smoke-tests" ]]; then
        return 0
    fi
    find "$SCRIPT_DIR/smoke-tests" -maxdepth 2 -name "test.sh" | sort -V
}

test_number() {
    basename "$(dirname "$1")" | cut -d'-' -f1
}

test_name() {
    basename "$(dirname "$1")" | cut -d'-' -f2-
}

print_usage() {
    cat <<'EOF'
Usage: ./smoke-tests.sh [COMMAND|TEST]

  (no args)           Run parallelisable tests in a rolling pool sized from the core count;
                      sequential-marked tests one at a time afterwards
  all                 Same as no args
  --sequential        Run all tests one at a time
  --parallel [N]      Run a pool of N; sequential-marked tests still run alone. Overrides the
                      core count and the PHOTOSPHERE_TEST_PARALLEL environment variable
  --binary            Run against the packaged release binary instead of source
  <X>                 Run test by number or fuzzy name
  ls, list            List all discovered tests
  help, --help, -?    Show this help

Environment:
  PHOTOSPHERE_TEST_PARALLEL   How many tests to run at once, in place of the core count. Set by
                              scripts/test-everything-parallel.sh so the lanes of one run share
                              the machine. A value that is not a positive integer is refused.
EOF
}

# Returns 0 if the test directory contains a .sequential marker file.
is_sequential() {
    local test_sh="$1"
    [[ -f "$(dirname "$test_sh")/.sequential" ]]
}

list_tests() {
    while IFS= read -r t; do
        printf "  %2s  %s\n" "$(test_number "$t")" "$(test_name "$t")"
    done < <(discover_tests)
}

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

run_one() {
    local test_sh="$1"
    local dir num name test_temp_dir log_file
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    # A directory of this test's own, shared with no other test and with no other run. The test
    # inherits it through the exported variables, so everything it and the app it starts write goes
    # inside it rather than into a fixed <test>/tmp that concurrent runs fought over.
    test_temp_dir="$(photosphere_test_temp_dir "$name")"
    photosphere_export_test_temp "$test_temp_dir"
    log_file="$test_temp_dir/test-run.log"
    printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
    local test_start=$SECONDS
    local status=0
    run_test_with_timeout "$PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1 || status=$?
    local test_duration
    test_duration=$(format_duration $((SECONDS - test_start)))

    if [ "$status" -eq 0 ]; then
        printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
        return 0
    fi

    # A test that ran out of time is called out as such rather than being reported as a failure like
    # any other. The two need different responses: a failure says the code is wrong, a timeout says
    # the test never got as far as deciding, and the summary cannot tell them apart on its own.
    if test_timed_out "$status"; then
        report_test_timeout "$name" "$PER_TEST_TIMEOUT" "$log_file"
    else
        printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
    fi
    FAILED_TEST_LOGS+=("$log_file")
    return 1
}

run_sequential() {
    local pass=0
    local fail=0
    for t in "$@"; do
        if run_one "$t"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    print_failed_logs
    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

# Seconds between looks at the running tests in run_parallel_pool. A tenth of a second, because this
# is what decides how long a freed slot sits empty before the next test starts, and the poll itself
# is a `kill -0` per running test.
POOL_POLL_INTERVAL=0.1

#
# Reports a finished test and counts it, taking the exit status the job left behind.
# Usage: report_pool_result <status> <test.sh> <temp_dir> <pass_var> <fail_var>
#
report_pool_result() {
    local status="$1"
    local test_sh="$2"
    local test_temp_dir="$3"
    local pass_var="$4"
    local fail_var="$5"
    local num name test_duration log_file
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$test_temp_dir/test-run.log"
    test_duration=$(format_duration "$(cat "$test_temp_dir/test-duration.txt" 2>/dev/null || echo 0)")

    if [ "$status" -eq 0 ]; then
        printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
        eval "$pass_var=$(( ${!pass_var} + 1 ))"
        return 0
    fi

    # The subshell exits with whatever run_test_with_timeout returned, so a test that ran out of time
    # still arrives here carrying the timeout code and can be named as one.
    if test_timed_out "$status"; then
        report_test_timeout "$name" "$PER_TEST_TIMEOUT" "$log_file"
    else
        printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s)\n" "$num" "$name" "$test_duration" "$log_file"
    fi
    FAILED_TEST_LOGS+=("$log_file")
    eval "$fail_var=$(( ${!fail_var} + 1 ))"
    return 0
}

#
# Runs a list of tests, keeping at most N of them going at once, and returns pass/fail via out-vars.
#
# A rolling pool rather than batches. Batches waited for every test in one before starting any of the
# next, so a batch cost as much as its slowest member and the machine sat idle for the difference:
# test 28 ran for 1m 2s while its partner sat finished for 42 seconds of it. Here a slot is refilled
# the moment the test in it finishes.
#
# Three indexed arrays hold the slots rather than one array of records, and the slots are polled with
# `kill -0` rather than waited on with `wait -n`, because the bash macOS ships is 3.2: it has neither
# associative arrays nor `wait -n`. `wait` is still what reads the exit status, and it returns
# immediately for a job already known to have finished.
#
# Results print as tests finish rather than in test order, which is what the batch runner already did
# within a batch.
# Usage: run_parallel_pool <n> <pass_var> <fail_var> <test...>
run_parallel_pool() {
    local n="$1"
    local pass_var="$2"
    local fail_var="$3"
    shift 3
    local tests=("$@")
    local total="${#tests[@]}"
    local next=0
    local in_flight=0

    # Slot i holds the pid of the test running in it, the test it is running and where that test was
    # told to write. An empty pid means the slot is free.
    local pool_pids=()
    local pool_tests=()
    local pool_temp_dirs=()
    local slot=0
    while ((slot < n)); do
        pool_pids[slot]=""
        pool_tests[slot]=""
        pool_temp_dirs[slot]=""
        slot=$((slot + 1))
    done

    while ((next < total || in_flight > 0)); do
        # Fill every free slot before looking at anything, so a test starts the moment there is room
        # for it.
        slot=0
        while ((slot < n && next < total)); do
            if [ -z "${pool_pids[slot]}" ]; then
                local test_sh test_temp_dir log_file
                test_sh="${tests[next]}"
                # Allocated out here rather than inside the job, because the pool needs it to find
                # the test's log and its duration once the job has gone, and a subshell cannot hand
                # a variable back to its parent.
                test_temp_dir="$(photosphere_test_temp_dir "$(test_name "$test_sh")")"
                log_file="$test_temp_dir/test-run.log"
                printf "${BLUE}RUN ${NC}  %2s  %s\n" "$(test_number "$test_sh")" "$(test_name "$test_sh")"
                # Started here in the pool's own shell, never through a command substitution: a job
                # started inside one is the subshell's child, so this shell could not `wait` for it
                # and would have no exit status to report.
                (
                    photosphere_export_test_temp "$test_temp_dir"
                    local_start=$SECONDS
                    run_test_with_timeout "$PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1
                    local_exit=$?
                    echo $((SECONDS - local_start)) > "$test_temp_dir/test-duration.txt"
                    exit $local_exit
                ) &
                pool_pids[slot]="$!"
                pool_tests[slot]="$test_sh"
                pool_temp_dirs[slot]="$test_temp_dir"
                in_flight=$((in_flight + 1))
                next=$((next + 1))
            fi
            slot=$((slot + 1))
        done

        sleep "$POOL_POLL_INTERVAL"

        slot=0
        while ((slot < n)); do
            local slot_pid="${pool_pids[slot]}"
            if [ -n "$slot_pid" ] && ! kill -0 "$slot_pid" 2>/dev/null; then
                local slot_status=0
                wait "$slot_pid" || slot_status=$?
                report_pool_result "$slot_status" "${pool_tests[slot]}" "${pool_temp_dirs[slot]}" "$pass_var" "$fail_var"
                pool_pids[slot]=""
                pool_tests[slot]=""
                pool_temp_dirs[slot]=""
                in_flight=$((in_flight - 1))
            fi
            slot=$((slot + 1))
        done
    done
}

# Runs parallelisable tests in a rolling pool and sequential-marked tests one at a time.
run_mixed() {
    local n="$1"
    shift
    # Said out loud, because the width is no longer a constant in this file: it comes from the
    # machine, from PHOTOSPHERE_TEST_PARALLEL or from --parallel, and a run that is slower than
    # expected should not need the source read to find out which.
    echo "Running up to $n tests at a time."
    local parallel_tests=()
    local sequential_tests=()
    for t in "$@"; do
        if is_sequential "$t"; then
            sequential_tests+=("$t")
        else
            parallel_tests+=("$t")
        fi
    done

    local pass=0
    local fail=0

    if [[ ${#parallel_tests[@]} -gt 0 ]]; then
        run_parallel_pool "$n" pass fail "${parallel_tests[@]}"
    fi

    for t in "${sequential_tests[@]}"; do
        if run_one "$t"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done

    print_failed_logs
    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

print_failed_logs() {
    if [ ${#FAILED_TEST_LOGS[@]} -eq 0 ]; then
        return
    fi
    echo ""
    echo "============================================================================"
    echo "FAILED TEST OUTPUT"
    echo "============================================================================"
    for log_file in "${FAILED_TEST_LOGS[@]}"; do
        local test_dir_name
        test_dir_name=$(basename "$(dirname "$(dirname "$log_file")")")
        echo ""
        echo "---------- $test_dir_name ($log_file) ----------"
        cat "$log_file"
        echo "---------- end $test_dir_name ----------"
    done
}

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

#
# Fails the run when anything this suite launched is still running at the end of it.
#
# A suite that leaks has failed, whatever its tests reported, because the cost lands on whatever runs
# next: enough leaked Electron trees and X servers and the machine runs out of memory and
# systemd-oomd starts killing things at random.
#
# It looks only at the process groups this suite's own launches recorded, so the four other suites
# that `bun run test:everything` runs alongside this one cannot be mistaken for its leak.
#
# The second look comes after a pause. The last test's cleanup signals its processes and returns
# without waiting for them, so looking immediately races the kernel finishing them off.
#
check_for_leaked_processes() {
    local leaked
    leaked="$(list_leaked_launches)"
    if [[ -z "$leaked" ]]; then
        return 0
    fi
    sleep 5
    leaked="$(list_leaked_launches)"
    if [[ -z "$leaked" ]]; then
        return 0
    fi

    echo ""
    printf "${RED}LEAK: this run left processes it started still running.${NC}\n"
    printf '%s\n' "$leaked" | while IFS= read -r leaked_line; do
        echo "  $leaked_line"
    done
    echo ""
    echo "Stop them before running again; they hold memory until something does."
    return 1
}

find_matching() {
    local pattern="$1"
    while IFS= read -r t; do
        local dir num
        dir="$(basename "$(dirname "$t")")"
        num="$(test_number "$t")"
        if [[ "$num" == "$pattern" || "$dir" == *"$pattern"* ]]; then
            echo "$t"
        fi
    done < <(discover_tests)
}

# Builds bundle/main.js and the renderer, which is what Electron is pointed at: apps/desktop's
# package.json names bundle/main.js as its main. The root `bun run bundle` is the one definition of
# that build, so this calls it rather than repeating its two halves here.
#
# PHOTOSPHERE_SKIP_DESKTOP_BUNDLE says the caller has already built it. scripts/test-everything-parallel.sh
# sets it after building once for the whole run, because this suite and
# cli-desktop-lan-share-smoke-tests.sh write the same directories and vite empties bundle/frontend
# before rewriting it, so two builds at once can delete the renderer the other is about to launch.
# Unset, which is how this suite runs on its own, the build happens here as it always did.
bundle_app() {
    if [[ "$USE_BINARY" == "true" ]]; then
        echo "Binary mode: skipping bundle step."
        return
    fi
    if [[ -n "${PHOTOSPHERE_SKIP_DESKTOP_BUNDLE:-}" ]]; then
        echo "Bundle already built by the caller (PHOTOSPHERE_SKIP_DESKTOP_BUNDLE is set): skipping bundle step."
        return
    fi
    echo "Bundling..."
    (cd "$REPO_DIR" && bun run bundle)
}

main() {
    local mode="parallel"
    # From the machine, or from PHOTOSPHERE_TEST_PARALLEL when a caller running other suites beside
    # this one has said what share it gets. 2 is what this suite ran at before it asked, and is what
    # a host that reports no core count still gets. An explicit --parallel N below beats both.
    local parallel_n
    parallel_n="$(resolve_test_parallel 2)" || exit 1
    local pattern=""
    local remaining_args=()

    for arg in "$@"; do
        if [[ "$arg" == "--binary" ]]; then
            USE_BINARY=true
        else
            remaining_args+=("$arg")
        fi
    done
    export USE_BINARY
    set -- "${remaining_args[@]+"${remaining_args[@]}"}"

    if [[ $# -gt 0 ]]; then
        case "$1" in
            help|--help|-\?|--\?)
                print_usage
                exit 0
                ;;
            ls|list)
                list_tests
                exit 0
                ;;
            all)
                mode="parallel"
                ;;
            --sequential)
                mode="sequential"
                ;;
            --parallel)
                mode="parallel"
                if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                    parallel_n="$2"
                fi
                ;;
            *)
                mode="single"
                pattern="$1"
                ;;
        esac
    fi

    if [[ "$mode" == "single" ]]; then
        local matching=()
        while IFS= read -r t; do
            matching+=("$t")
        done < <(find_matching "$pattern")
        if [[ ${#matching[@]} -eq 0 ]]; then
            echo "No tests match: $pattern"
            exit 1
        fi
        bundle_app
        local single_status=0
        run_sequential "${matching[@]}" || single_status=$?
        check_for_leaked_processes || single_status=1
        rm -f "$PHOTOSPHERE_LAUNCHED_GROUPS"
        exit "$single_status"
    fi

    local all_tests=()
    while IFS= read -r t; do
        all_tests+=("$t")
    done < <(discover_tests)

    if [[ ${#all_tests[@]} -eq 0 ]]; then
        echo "No tests found in smoke-tests/"
        exit 0
    fi

    bundle_app

    local run_status=0
    if [[ "$mode" == "sequential" ]]; then
        run_sequential "${all_tests[@]}" || run_status=$?
    else
        run_mixed "$parallel_n" "${all_tests[@]}" || run_status=$?
    fi
    check_for_leaked_processes || run_status=1
    rm -f "$PHOTOSPHERE_LAUNCHED_GROUPS"
    return "$run_status"
}

main "$@"
