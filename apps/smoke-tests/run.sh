#!/usr/bin/env bash
set -euo pipefail

# Discovers and runs the mobile smoke tests (tests/*/test.sh) on the platform given by the
# PLATFORM env var (android or ios). Builds and installs the app once up front, then runs each
# test sequentially. Mirrors apps/desktop/smoke-tests.sh but simpler (sequential only) and
# without an in-app control server (the host control bridge handles that, see lib/common.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${PLATFORM:?PLATFORM must be set to 'android' or 'ios'}"

# Sourcing common.sh also sources the platform launcher and defines the *_prepare/_build/etc.
source "$SCRIPT_DIR/lib/common.sh"

discover_tests() {
    find "$SCRIPT_DIR/tests" -maxdepth 2 -name "test.sh" 2>/dev/null | sort -V
}

main() {
    "${PLATFORM}_prepare"
    "${PLATFORM}_build"
    "${PLATFORM}_install"

    # Clear the app's data from the device however the run ends, so the databases the tests seed and
    # import into do not pile up until the device runs out of storage.
    trap "${PLATFORM}_cleanup" EXIT

    local tests=()
    while IFS= read -r test_path; do
        tests+=("$test_path")
    done < <(discover_tests)

    if [ ${#tests[@]} -eq 0 ]; then
        echo "No tests found in tests/"
        exit 0
    fi

    local pass=0
    local fail=0
    for test_path in "${tests[@]}"; do
        local dir name
        dir="$(dirname "$test_path")"
        name="$(basename "$dir")"
        rm -rf "$dir/tmp"
        printf "${BLUE}RUN ${NC}  %s\n" "$name"
        if bash "$test_path"; then
            printf "${GREEN}PASS${NC}  %s\n" "$name"
            pass=$((pass + 1))
        else
            printf "${RED}FAIL${NC}  %s\n" "$name"
            fail=$((fail + 1))
        fi
    done

    echo ""
    if [ "$fail" -eq 0 ]; then
        printf "${GREEN}All %d tests passed${NC}\n" "$pass"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$((pass + fail))"
    fi
    return $((fail > 0 ? 1 : 0))
}

main "$@"
