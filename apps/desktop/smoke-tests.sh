#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

USE_BINARY=false

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

run_one() {
    local test_sh="$1"
    local dir num name log_file
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$dir/tmp/test-run.log"
    mkdir -p "$dir/tmp"
    printf "${BLUE}RUN ${NC}   %s  %s\n" "$num" "$name"
    if timeout 300 bash "$test_sh" >"$log_file" 2>&1; then
        printf "${GREEN}PASS${NC}  %s  %s\n" "$num" "$name"
        return 0
    else
        printf "${RED}FAIL${NC}  %s  %s  (log: %s)\n" "$num" "$name" "$log_file"
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
            printf "${BLUE}RUN ${NC}   %s  %s\n" "$num" "$name"
            timeout 300 bash "$t" >"$log_file" 2>&1 &
            batch_pids+=($!)
        done

        local k=0
        for pid in "${batch_pids[@]}"; do
            local t num name
            t="${batch_tests[$k]}"
            num="$(test_number "$t")"
            name="$(test_name "$t")"
            if wait "$pid"; then
                printf "${GREEN}PASS${NC}  %s  %s\n" "$num" "$name"
                eval "$pass_var=$(( ${!pass_var} + 1 ))"
            else
                printf "${RED}FAIL${NC}  %s  %s  (log: %s/tmp/test-run.log)\n" "$num" "$name" "$(dirname "$t")"
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

    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}

print_summary() {
    local pass="$1"
    local fail="$2"
    local total=$((pass + fail))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d tests passed${NC}\n" "$total"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$total"
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
