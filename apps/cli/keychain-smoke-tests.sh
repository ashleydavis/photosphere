#!/bin/bash

# Photosphere CLI Keychain Smoke Tests
# Tests OS keychain vault operations. Run separately from smoke-tests.sh because
# the OS keychain is global system state and cannot be safely parallelised.
# Intended for use in the release workflow on each target platform.

KEYCHAIN_TESTS_DIR="$(cd "$(dirname "$0")" && pwd)/smoke-tests-key-chain"

export NODE_ENV=testing
export NO_COLOR=1

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp-keychain}"
USE_BINARY=false

KEYCHAIN_SCRIPTS=(
    "$KEYCHAIN_TESTS_DIR/58-keychain-vault-list-empty/test.sh"
    "$KEYCHAIN_TESTS_DIR/59-keychain-vault-add/test.sh"
    "$KEYCHAIN_TESTS_DIR/60-keychain-vault-view/test.sh"
    "$KEYCHAIN_TESTS_DIR/61-keychain-vault-edit/test.sh"
    "$KEYCHAIN_TESTS_DIR/62-keychain-vault-delete/test.sh"
    "$KEYCHAIN_TESTS_DIR/63-keychain-vault-list-multiple/test.sh"
)

test_number() {
    basename "$(dirname "$1")" | grep -oE '^[0-9]+'
}

test_name() {
    basename "$(dirname "$1")" | sed 's/^[0-9]*-//'
}

run_one() {
    local test_sh="$1"
    local num name log_file
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$(dirname "$test_sh")/tmp/test-run.log"
    mkdir -p "$(dirname "$test_sh")/tmp"
    export ISOLATED_TEST_TMP_DIR="${TEST_TMP_DIR}/$(basename "$(dirname "$test_sh")")"
    printf "${BLUE}RUN ${NC}  %s  %s\n" "$num" "$name"
    if timeout 300 bash "$test_sh" >"$log_file" 2>&1; then
        printf "${GREEN}PASS${NC}  %s  %s\n" "$num" "$name"
        return 0
    else
        printf "${RED}FAIL${NC}  %s  %s  (log: %s)\n" "$num" "$name" "$log_file"
        return 1
    fi
}

main() {
    cd "$(dirname "$0")"

    export TEST_TMP_DIR USE_BINARY

    echo "======================================"
    echo "Photosphere CLI Keychain Smoke Tests"
    echo "======================================"

    local pass=0
    local fail=0

    for test_sh in "${KEYCHAIN_SCRIPTS[@]}"; do
        if run_one "$test_sh"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done

    local total=$((pass + fail))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d keychain tests passed${NC}\n" "$total"
        exit 0
    else
        printf "${RED}%d of %d keychain tests failed${NC}\n" "$fail" "$total"
        exit 1
    fi
}

main "$@"
