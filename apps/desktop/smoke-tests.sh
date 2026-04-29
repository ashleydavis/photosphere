#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

USE_BINARY=false

# Record start time for total duration reporting
SMOKE_TESTS_START_TIME=$SECONDS

# Track log files for failed tests so we can dump them after the summary
FAILED_TEST_LOGS=()

# macOS and Windows lack GNU timeout; provide a compatible implementation
_timeout_fallback() {
    local duration="$1"
    shift
    "$@" &
    local child_pid=$!
    ( sleep "$duration" && kill "$child_pid" 2>/dev/null ) &
    local killer_pid=$!
    wait "$child_pid"
    local exit_status=$?
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    return $exit_status
}

if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v gtimeout &>/dev/null; then
        timeout() { gtimeout "$@"; }
    else
        timeout() { _timeout_fallback "$@"; }
    fi
elif [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    timeout() { _timeout_fallback "$@"; }
fi

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

  (no args)           Run parallelisable tests in batches of 2; sequential-marked tests one at a time
  all                 Same as no args
  --sequential        Run all tests one at a time
  --parallel [N]      Run in parallel batches of N (default 2); sequential-marked tests still run alone
  --binary            Run against the packaged release binary instead of source
  <X>                 Run test by number or fuzzy name
  ls, list            List all discovered tests
  help, --help, -?    Show this help
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
    local dir num name log_file
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$dir/tmp/test-run.log"
    mkdir -p "$dir/tmp"
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
        FAILED_TEST_LOGS+=("$log_file")
        return 1
    fi
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

# Runs a list of tests in parallel batches of N, returning pass/fail via out-vars.
# Usage: run_parallel_batch <n> <pass_var> <fail_var> <test...>
run_parallel_batch() {
    local n="$1"
    local pass_var="$2"
    local fail_var="$3"
    shift 3
    local tests=("$@")
    local total="${#tests[@]}"
    local i=0

    while ((i < total)); do
        local batch_tests=()
        local batch_pids=()
        local j=0
        while ((j < n && i < total)); do
            batch_tests+=("${tests[i]}")
            i=$((i + 1))
            j=$((j + 1))
        done

        for t in "${batch_tests[@]}"; do
            local dir log_file num name
            dir="$(dirname "$t")"
            num="$(test_number "$t")"
            name="$(test_name "$t")"
            log_file="$dir/tmp/test-run.log"
            mkdir -p "$dir/tmp"
            printf "${BLUE}RUN ${NC}  %2s  %s\n" "$num" "$name"
            (
                local_start=$SECONDS
                timeout 300 bash "$t" >"$log_file" 2>&1
                local_exit=$?
                echo $((SECONDS - local_start)) > "$dir/tmp/test-duration.txt"
                exit $local_exit
            ) &
            batch_pids+=($!)
        done

        local k=0
        for pid in "${batch_pids[@]}"; do
            local t num name
            t="${batch_tests[$k]}"
            num="$(test_number "$t")"
            name="$(test_name "$t")"
            local duration_file
            duration_file="$(dirname "$t")/tmp/test-duration.txt"
            local test_duration
            if wait "$pid"; then
                test_duration=$(format_duration "$(cat "$duration_file" 2>/dev/null || echo 0)")
                printf "${GREEN}PASS${NC}  %2s  %-30s  %s\n" "$num" "$name" "$test_duration"
                eval "$pass_var=$(( ${!pass_var} + 1 ))"
            else
                test_duration=$(format_duration "$(cat "$duration_file" 2>/dev/null || echo 0)")
                printf "${RED}FAIL${NC}  %2s  %-30s  %s  (log: %s/tmp/test-run.log)\n" "$num" "$name" "$test_duration" "$(dirname "$t")"
                FAILED_TEST_LOGS+=("$(dirname "$t")/tmp/test-run.log")
                eval "$fail_var=$(( ${!fail_var} + 1 ))"
            fi
            k=$((k + 1))
        done
    done
}

# Runs parallelisable tests in batches and sequential-marked tests one at a time.
run_mixed() {
    local n="$1"
    shift
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
        run_parallel_batch "$n" pass fail "${parallel_tests[@]}"
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

bundle_app() {
    if [[ "$USE_BINARY" == "true" ]]; then
        echo "Binary mode: skipping bundle step."
        return
    fi
    echo "Bundling..."
    cd "$SCRIPT_DIR/../desktop-frontend" && bun run bundle
    cd "$SCRIPT_DIR" && bun run bundle
}

main() {
    local mode="parallel"
    local parallel_n=2
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
        run_sequential "${matching[@]}"
        exit $?
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

    if [[ "$mode" == "sequential" ]]; then
        run_sequential "${all_tests[@]}"
    else
        run_mixed "$parallel_n" "${all_tests[@]}"
    fi
}

main "$@"
