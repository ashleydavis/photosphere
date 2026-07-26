#!/usr/bin/env bash
set -euo pipefail

# Discovers and runs the mobile smoke tests (tests/*/test.sh) on the platform given by the
# PLATFORM env var (android or ios). Builds and installs the app once up front, then spreads the
# tests over the available devices. Mirrors apps/desktop/smoke-tests.sh but without an in-app
# control server (the host control bridge handles that, see lib/common.sh).

# Nothing in a test run may read the terminal. This is a non-interactive suite, but the build
# toolchain underneath it (cap sync, Gradle) can try stdin, and a backgrounded job that reads the
# tty is stopped by the kernel with SIGTTIN. That made `bun run test:and &` suspend instead of run,
# so several suites could not be started from one terminal without redirecting stdin by hand.
# Detaching stdin here means backgrounding just works, with no ceremony at the call site.
exec </dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${PLATFORM:?PLATFORM must be set to 'android' or 'ios'}"

# Sourcing common.sh also sources the platform launcher and defines the *_prepare/_build/etc.
source "$SCRIPT_DIR/lib/common.sh"

# Give this run its own per-test scratch directory before anything reads it, so several suites can
# run at once out of one checkout without wiping each other's live test state. Exported, because each
# test.sh is a separate process that builds its TMP_DIR from it.
export PHOTOSPHERE_TEST_TMP="${PHOTOSPHERE_TEST_TMP:-tmp/run-$$}"

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
        with_device "$slot" "${PLATFORM}_cleanup"
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

    # One suite builds at a time: concurrent builds out of one checkout corrupt each other.
    with_build_lock "${PLATFORM}_build"

    # Every ready device is a candidate. Nothing is reserved here: a worker takes an emulator for one
    # test and hands it back, so other suites running at the same time get their turn too.
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
        with_device "$slot" "${PLATFORM}_install"
    done

    # Clear the app's data from every device however the run ends, so the databases the tests seed
    # and import into do not pile up until a device runs out of storage. Deregistering here too, so
    # an interrupted run does not leave a registration behind shrinking the other suites' shares.
    trap 'cleanup_all_devices; deregister_suite' EXIT

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
            printf "${RED}  %s${NC}  (log: %s)\n" "$name" "$SCRIPT_DIR/tests/$name/$RUN_TMP_NAME/test-run.log"
        done
    fi
    return $((fail > 0 ? 1 : 0))
}

main "$@"
