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

# The work queue and worker pool that spread the tests over the available devices.
source "$SCRIPT_DIR/lib/runner.sh"

discover_tests() {
    find "$SCRIPT_DIR/tests" -maxdepth 2 -name "test.sh" 2>/dev/null | sort -V
}

#
# Clears the app's data from every device the run used. Runs from the EXIT trap, so it must not
# leave ANDROID_SERIAL pointing at whichever device happened to be last.
#
cleanup_all_devices() {
    local slot
    for slot in "${RUNNER_SLOTS[@]}"; do
        "${PLATFORM}_export_device" "$slot"
        "${PLATFORM}_cleanup"
    done
}

main() {
    # Optional first argument narrows the run to test dirs whose name contains it (e.g.
    # "29-stale-recent-database" or "stale-recent"), so a single test can be iterated without the
    # full build-install-27-tests cycle. An absent argument runs every test.
    local filter="${1:-}"

    # Android: fail immediately unless the emulator is already started and on the LAN bridge. This
    # never boots or changes the emulator; readiness is set up by hand. The single-run lock is taken
    # outside this script by android-lock.sh, which `test:and` wraps this run in.
    if [ "$PLATFORM" = "android" ]; then
        android_require_ready
    fi

    "${PLATFORM}_prepare"
    "${PLATFORM}_build"

    # One worker per device. The app is built once and installed onto each of them.
    RUNNER_SLOTS=()
    while IFS= read -r slot; do
        RUNNER_SLOTS+=("$slot")
    done < <("${PLATFORM}_device_slots")

    if [ ${#RUNNER_SLOTS[@]} -eq 0 ]; then
        log_error "No usable device found for $PLATFORM."
        exit 1
    fi

    log_info "Running on ${#RUNNER_SLOTS[@]} device(s): ${RUNNER_SLOTS[*]}"

    local slot
    for slot in "${RUNNER_SLOTS[@]}"; do
        "${PLATFORM}_export_device" "$slot"
        "${PLATFORM}_install"
    done

    # Clear the app's data from every device however the run ends, so the databases the tests seed
    # and import into do not pile up until a device runs out of storage.
    trap 'cleanup_all_devices' EXIT

    local tests=()
    while IFS= read -r test_path; do
        local test_name
        test_name="$(basename "$(dirname "$test_path")")"
        if [ -n "$filter" ] && [[ "$test_name" != *"$filter"* ]]; then
            continue
        fi
        tests+=("$test_path")
    done < <(discover_tests)

    if [ ${#tests[@]} -eq 0 ]; then
        if [ -n "$filter" ]; then
            # A filter that matches nothing is an error, not a silent zero-test pass.
            echo "No tests matched filter: $filter"
            exit 1
        fi
        echo "No tests found in tests/"
        exit 0
    fi

    # The slowest test starts first, so it is not the last thing still running while every other
    # worker sits idle.
    local ordered=()
    while IFS= read -r test_path; do
        ordered+=("$test_path")
    done < <(order_tests "${tests[@]}")

    local results_dir
    results_dir="$(mktemp -d)"
    run_pool "$results_dir" "${ordered[@]}" || true

    local pass=0
    local fail=0
    local failed_names=()
    local result_file verdict name
    for result_file in "$results_dir"/*.result; do
        [ -e "$result_file" ] || continue
        verdict="$(awk '{ print $1 }' "$result_file")"
        name="$(awk '{ print $2 }' "$result_file")"
        if [ "$verdict" = "pass" ]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            failed_names+=("$name")
        fi
    done
    rm -rf "$results_dir"

    echo ""
    if [ "$fail" -eq 0 ]; then
        printf "${GREEN}All %d tests passed${NC}\n" "$pass"
    else
        # Workers interleave their output, so each failure's log path is printed here rather than
        # leaving it to be hunted for in the scrollback.
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$((pass + fail))"
        for name in "${failed_names[@]}"; do
            printf "${RED}  %s${NC}  (log: %s)\n" "$name" "$SCRIPT_DIR/tests/$name/tmp/test-run.log"
        done
    fi
    return $((fail > 0 ? 1 : 0))
}

main "$@"
