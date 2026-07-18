#!/usr/bin/env bash
set -euo pipefail

# Discovers and runs UI smoke tests (tests/*/test.sh) on the platform given by the
# PLATFORM env var (android, ios, or electron). Builds and installs the app once up front.
# Electron defaults to parallel batches of 2 (with .sequential markers run alone); android/ios
# default to sequential (device contention). See --help.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${PLATFORM:?PLATFORM must be set to 'android', 'ios', or 'electron'}"

# Sourcing common.sh also sources the platform launcher and defines the *_prepare/_build/etc.
source "$SCRIPT_DIR/lib/common.sh"

USE_BINARY=false
export USE_BINARY

PER_TEST_TIMEOUT=300
SMOKE_TESTS_START_TIME=$SECONDS
FAILED_TEST_LOGS=()

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

if [[ "${OSTYPE:-}" == "darwin"* ]]; then
    if command -v gtimeout &>/dev/null; then
        timeout() { gtimeout "$@"; }
    else
        timeout() { _timeout_fallback "$@"; }
    fi
elif [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
    timeout() { _timeout_fallback "$@"; }
fi

handle_interrupt() {
    echo ""
    echo "Interrupted."
    jobs -p | xargs -r kill -TERM 2>/dev/null
    exit 130
}

trap handle_interrupt INT

discover_tests() {
    find "$SCRIPT_DIR/tests" -maxdepth 2 -name "test.sh" 2>/dev/null | sort -V
}

test_number() {
    basename "$(dirname "$1")" | cut -d'-' -f1
}

test_name() {
    basename "$(dirname "$1")" | cut -d'-' -f2-
}

is_sequential() {
    local test_sh="$1"
    [[ -f "$(dirname "$test_sh")/.sequential" ]]
}

print_usage() {
    cat <<EOF
Usage: PLATFORM=<android|ios|electron> ./run.sh [COMMAND|TEST]

  (no args)           Electron: parallel batches of 2 (+ .sequential alone).
                      Android/iOS: sequential.
  all                 Same as no args
  --sequential        Run all tests one at a time
  --parallel [N]      Run in parallel batches of N (default 2); .sequential still alone
  --binary            Electron only: run against the packaged release binary
  <X>                 Run test by number or fuzzy name
  ls, list            List all discovered tests
  help, --help, -?    Show this help
EOF
}

list_tests() {
    while IFS= read -r t; do
        local marker=""
        if is_sequential "$t"; then
            marker=" [sequential]"
        fi
        printf "  %2s  %s%s\n" "$(test_number "$t")" "$(test_name "$t")" "$marker"
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
    rm -rf "$dir/tmp"
    mkdir -p "$dir/tmp"
    printf "${BLUE}RUN ${NC}  %s-%s\n" "$num" "$name"
    if timeout "$PER_TEST_TIMEOUT" bash "$test_sh" >"$log_file" 2>&1; then
        printf "${GREEN}PASS${NC}  %s-%s\n" "$num" "$name"
        return 0
    else
        local exit_code=$?
        printf "${RED}FAIL${NC}  %s-%s\n" "$num" "$name"
        FAILED_TEST_LOGS+=("$log_file")
        return "$exit_code"
    fi
}

run_sequential() {
    local pass=0
    local fail=0
    local t
    for t in "$@"; do
        if run_one "$t"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    echo "$pass" > "$SCRIPT_DIR/.last-pass-count"
    echo "$fail" > "$SCRIPT_DIR/.last-fail-count"
    return $((fail > 0 ? 1 : 0))
}

run_parallel_batch() {
    local n="$1"
    shift
    local pass=0
    local fail=0
    local -a batch=()
    local t

    flush_batch() {
        local i pids=()
        for i in "${!batch[@]}"; do
            run_one "${batch[$i]}" &
            pids+=($!)
        done
        for i in "${!pids[@]}"; do
            if wait "${pids[$i]}"; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
            fi
        done
        batch=()
    }

    for t in "$@"; do
        batch+=("$t")
        if [ "${#batch[@]}" -ge "$n" ]; then
            flush_batch
        fi
    done
    if [ "${#batch[@]}" -gt 0 ]; then
        flush_batch
    fi
    echo "$pass" > "$SCRIPT_DIR/.last-pass-count"
    echo "$fail" > "$SCRIPT_DIR/.last-fail-count"
    return $((fail > 0 ? 1 : 0))
}

run_mixed() {
    local n="$1"
    shift
    local -a parallel_tests=()
    local -a sequential_tests=()
    local t
    for t in "$@"; do
        if is_sequential "$t"; then
            sequential_tests+=("$t")
        else
            parallel_tests+=("$t")
        fi
    done

    local pass=0 fail=0
    if [ ${#parallel_tests[@]} -gt 0 ]; then
        run_parallel_batch "$n" "${parallel_tests[@]}" || true
        pass=$(cat "$SCRIPT_DIR/.last-pass-count")
        fail=$(cat "$SCRIPT_DIR/.last-fail-count")
    fi
    if [ ${#sequential_tests[@]} -gt 0 ]; then
        run_sequential "${sequential_tests[@]}" || true
        pass=$((pass + $(cat "$SCRIPT_DIR/.last-pass-count")))
        fail=$((fail + $(cat "$SCRIPT_DIR/.last-fail-count")))
    fi
    echo "$pass" > "$SCRIPT_DIR/.last-pass-count"
    echo "$fail" > "$SCRIPT_DIR/.last-fail-count"
    return $((fail > 0 ? 1 : 0))
}

dump_failed_logs() {
    local log_file
    for log_file in "${FAILED_TEST_LOGS[@]+"${FAILED_TEST_LOGS[@]}"}"; do
        echo ""
        echo "======== FAILED: $log_file ========"
        cat "$log_file" 2>/dev/null || true
    done
}

main() {
    local mode="default"
    local parallel_n=2
    local -a filter=()
    local arg

    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            help|--help|-?)
                print_usage
                exit 0
                ;;
            ls|list)
                list_tests
                exit 0
                ;;
            all)
                ;;
            --sequential)
                mode="sequential"
                ;;
            --parallel)
                mode="parallel"
                if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    parallel_n="$1"
                    shift
                fi
                ;;
            --binary)
                USE_BINARY=true
                export USE_BINARY
                ;;
            *)
                filter+=("$arg")
                ;;
        esac
    done

    "${PLATFORM}_prepare"
    "${PLATFORM}_build"
    "${PLATFORM}_install"

    trap "${PLATFORM}_cleanup" EXIT

    local -a all_tests=()
    while IFS= read -r test_path; do
        all_tests+=("$test_path")
    done < <(discover_tests)

    if [ ${#all_tests[@]} -eq 0 ]; then
        echo "No tests found in tests/"
        exit 0
    fi

    local -a matched=()
    if [ ${#filter[@]} -gt 0 ]; then
        local f t
        for f in "${filter[@]}"; do
            for t in "${all_tests[@]}"; do
                local num name dirbase
                num="$(test_number "$t")"
                name="$(test_name "$t")"
                dirbase="$(basename "$(dirname "$t")")"
                if [ "$f" = "$num" ] || [[ "$dirbase" == *"$f"* ]] || [[ "$name" == *"$f"* ]]; then
                    matched+=("$t")
                fi
            done
        done
        if [ ${#matched[@]} -eq 0 ]; then
            log_error "No tests matched: ${filter[*]}"
            exit 1
        fi
    else
        matched=("${all_tests[@]}")
    fi

    # Default mode: electron parallel-mixed; mobile sequential.
    if [ "$mode" = "default" ]; then
        if [ "$PLATFORM" = "electron" ]; then
            mode="mixed"
        else
            mode="sequential"
        fi
    fi

    local rc=0
    case "$mode" in
        sequential)
            run_sequential "${matched[@]}" || rc=$?
            ;;
        parallel)
            run_parallel_batch "$parallel_n" "${matched[@]}" || rc=$?
            ;;
        mixed)
            run_mixed "$parallel_n" "${matched[@]}" || rc=$?
            ;;
    esac

    local pass fail
    pass=$(cat "$SCRIPT_DIR/.last-pass-count" 2>/dev/null || echo 0)
    fail=$(cat "$SCRIPT_DIR/.last-fail-count" 2>/dev/null || echo 0)
    rm -f "$SCRIPT_DIR/.last-pass-count" "$SCRIPT_DIR/.last-fail-count"

    dump_failed_logs

    echo ""
    local elapsed=$((SECONDS - SMOKE_TESTS_START_TIME))
    if [ "$fail" -eq 0 ]; then
        printf "${GREEN}All %d tests passed${NC} in %s\n" "$pass" "$(format_duration "$elapsed")"
    else
        printf "${RED}%d of %d tests failed${NC} in %s\n" "$fail" "$((pass + fail))" "$(format_duration "$elapsed")"
    fi
    return "$rc"
}

main "$@"
