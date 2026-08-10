#!/usr/bin/env bash
#
# One per-test timeout for every smoke test suite in this repository, and one way of reporting it.
#
# Before this, each suite did its own thing: the mobile runner allowed 600 seconds, the Electron
# suite 300, the CLI suite 300 written out at three separate call sites, the CLI LAN share suite 90,
# and four suites (encrypted, sync, write-lock, hash-cache) had no per-test limit at all. A wedged
# test in one of those four ran until something above it gave up, which in CI is the job timeout,
# and a job killed by its own timeout has its log discarded by GitHub rather than written. So the
# suites that most needed to explain themselves were the ones that could not.
#
# The value is deliberately the same everywhere. Suites differ in what they drive, but nothing about
# a CLI test makes a sensible ceiling different from a mobile one: the ceiling is not a budget for
# the work, it is the point past which the test is not running any more, it is stuck. Picking it per
# suite invites the number to drift towards whatever the slowest test happened to take that week.
#
# 300 seconds, against a slowest legitimate test of about 75 seconds measured across the suites
# (37-lan-share-timeout waits out a real 60 second window and lands at 69 to 70 seconds;
# 43-s3-failure takes 72). That is four times the slowest real test, which leaves room for a machine
# running several suites at once without leaving a hung test sitting there for an hour.
#

# Guard against being sourced twice through two different suites in one shell.
if [ -n "${PHOTOSPHERE_TEST_TIMEOUT_SOURCED:-}" ]; then
    return 0
fi
PHOTOSPHERE_TEST_TIMEOUT_SOURCED=1

TEST_TIMEOUT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/process-control.sh
source "$TEST_TIMEOUT_LIB_DIR/process-control.sh"

# Seconds any single test may run before it is treated as stuck. Overridable so a developer chasing
# one slow test does not have to edit this file, but every suite reads the same default.
PHOTOSPHERE_PER_TEST_TIMEOUT="${PHOTOSPHERE_PER_TEST_TIMEOUT:-300}"

# The exit code a timed-out test reports. 124 is what GNU timeout uses, so the value is the same
# whether the timeout came from timeout(1) or from the fallback below, and a caller can tell "this
# test was stuck" apart from "this test failed" by the code alone. Nothing else in these suites
# exits 124.
TEST_TIMED_OUT_EXIT_CODE=124

#
# Runs a command under the per-test timeout and returns TEST_TIMED_OUT_EXIT_CODE if it runs out.
#
# GNU timeout is used wherever it exists because it already handles the hard cases. --kill-after
# follows the TERM with a KILL for a test that ignores the first signal, and its own exit code for a
# timeout is 124.
#
# The fallback is for macOS and Git Bash, which ship neither timeout nor gtimeout. Two things in it
# are load-bearing and were both paid for:
#
#   The killer's output goes to /dev/null. A background job inherits the caller's stdout, so when the
#   caller is a pipeline or a $( ) capture the killer holds the write end of that pipe open. The
#   reader sees no end-of-file until the sleep expires and the call takes the full timeout however
#   fast the command was. That turned every iOS test into a flat 600 seconds and ran the job into its
#   90 minute limit.
#
#   The kill goes through kill_process_tree, not kill. A test script launches an app, a server, an
#   emulator bridge; killing the script's own pid leaves those running, still holding the port or the
#   device that the next test needs. The tree walk reaches them.
#
# Usage: run_test_with_timeout <seconds> <command...>
#
run_test_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5 "$seconds" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout --kill-after=5 "$seconds" "$@"
        return $?
    fi

    "$@" &
    local child_pid=$!
    local timed_out_marker
    timed_out_marker="$(mktemp "${TMPDIR:-/tmp}/photosphere-test-timeout-XXXXXX")"
    rm -f "$timed_out_marker"

    (
        sleep "$seconds"
        # Recorded before the kill, so the marker exists by the time wait returns below.
        : > "$timed_out_marker"
        kill_process_tree "$child_pid"
    ) >/dev/null 2>&1 &
    local killer_pid=$!

    wait "$child_pid"
    local child_status=$?

    kill "$killer_pid" 2>/dev/null || true
    # The sleep is a child of the killer and outlives it, so it is stopped too rather than left to
    # expire in its own time.
    pkill -P "$killer_pid" 2>/dev/null || true
    wait "$killer_pid" 2>/dev/null || true

    if [ -f "$timed_out_marker" ]; then
        rm -f "$timed_out_marker"
        return "$TEST_TIMED_OUT_EXIT_CODE"
    fi
    rm -f "$timed_out_marker"
    return "$child_status"
}

#
# True when the given exit code came from the per-test timeout rather than from the test itself.
# Usage: if test_timed_out "$status"; then ...
#
test_timed_out() {
    [ "$1" = "$TEST_TIMED_OUT_EXIT_CODE" ]
}

#
# Runs one test that is a shell function in this script rather than a separate script, and holds it
# to the shared timeout. Used by the encrypted and CLI-to-desktop LAN share suites, whose tests
# report their result by incrementing counters in the calling shell and so cannot be run in a
# subprocess without losing that.
#
# A watchdog gets the same effect from the outside: after the timeout it kills the script's children,
# which is whatever command the test is blocked on, and the function then unblocks and finishes. The
# script itself is left alone, so the suite carries on and reports. The watchdog skips its own pid,
# being a child of the script too, and polls for the script rather than trusting a trap to cancel it,
# because these suites install their own EXIT traps that would replace one.
#
# Returns 0 if the test function succeeded within the time, and 1 if it failed or ran out of time.
# Usage: run_test_function_with_timeout <test_name> <function_name>
#
run_test_function_with_timeout() {
    local test_name="$1"
    local test_function="$2"
    local script_pid=$$

    local timeout_marker
    timeout_marker="$(mktemp "${TMPDIR:-/tmp}/photosphere-fn-timeout-XXXXXX")"
    rm -f "$timeout_marker"

    (
        local waited=0
        while [ "$waited" -lt "$PHOTOSPHERE_PER_TEST_TIMEOUT" ]; do
            if ! kill -0 "$script_pid" 2>/dev/null; then
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done
        : > "$timeout_marker"
        local child
        for child in $(pgrep -P "$script_pid" 2>/dev/null); do
            if [ "$child" = "$BASHPID" ]; then
                continue
            fi
            kill_process_tree "$child"
        done
    ) >/dev/null 2>&1 &
    local watchdog_pid=$!

    local status=0
    "$test_function" || status=$?

    kill "$watchdog_pid" 2>/dev/null || true
    pkill -P "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -f "$timeout_marker" ]; then
        rm -f "$timeout_marker"
        report_test_timeout "$test_name" "$PHOTOSPHERE_PER_TEST_TIMEOUT" ""
        return 1
    fi
    rm -f "$timeout_marker"
    return "$status"
}

#
# Holds a whole script to the per-test timeout, for the suites that are one script rather than a set
# of separate tests (the sync, write-lock and hash-cache suites). There is no individual test in
# those to cap, so the script itself is the unit.
#
# The watchdog kills the calling script's children first, so whatever command it is blocked on lets
# go, and then the script itself, which makes the run exit non-zero and fail the suite. It reports
# before killing anything, because after the kill there is nobody left to report.
#
# Its own pid is skipped: the watchdog is a child of the script too and would otherwise be the first
# thing it killed.
#
# Usage: start_suite_watchdog <suite_name>   ... then stop_suite_watchdog at the end
#
start_suite_watchdog() {
    local suite_name="$1"
    local script_pid=$$

    (
        # Polled rather than one long sleep, and the poll checks the script is still alive. These
        # suites already install their own EXIT traps, so a watchdog that relied on being cancelled by
        # one would be left running whenever a script replaced the trap, and would later fire against
        # a pid the kernel had given to something else. Watching for the parent to disappear means it
        # cleans itself up whatever the script does with its traps.
        local waited=0
        while [ "$waited" -lt "$PHOTOSPHERE_PER_TEST_TIMEOUT" ]; do
            if ! kill -0 "$script_pid" 2>/dev/null; then
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done

        report_test_timeout "$suite_name" "$PHOTOSPHERE_PER_TEST_TIMEOUT" "" >&2
        local child
        for child in $(pgrep -P "$script_pid" 2>/dev/null); do
            if [ "$child" = "$BASHPID" ]; then
                continue
            fi
            kill_process_tree "$child"
        done
        kill -TERM "$script_pid" 2>/dev/null || true
    ) &
    SUITE_WATCHDOG_PID=$!
}

#
# Cancels the watchdog started by start_suite_watchdog. Safe to call when none was started.
# Usage: stop_suite_watchdog
#
stop_suite_watchdog() {
    if [ -z "${SUITE_WATCHDOG_PID:-}" ]; then
        return 0
    fi
    kill "$SUITE_WATCHDOG_PID" 2>/dev/null || true
    # The sleep is a child of the watchdog and outlives it, so it is stopped too.
    pkill -P "$SUITE_WATCHDOG_PID" 2>/dev/null || true
    wait "$SUITE_WATCHDOG_PID" 2>/dev/null || true
    SUITE_WATCHDOG_PID=""
}

#
# Prints everything known about a test that was killed for running too long.
#
# A timeout and a failed assertion look identical in a suite summary otherwise, and they need
# different responses: one says the code is wrong, the other says the test never got to the point of
# deciding. This says which it was, how long it was given, where the whole log is, and what the test
# had managed to write before it stopped, because the last thing a stuck test printed is usually the
# thing it was waiting for.
#
# Usage: report_test_timeout <test_name> <seconds> <log_file>
#
report_test_timeout() {
    local test_name="$1"
    local seconds="$2"
    local log_file="$3"

    # The one-line marker lives here rather than at each call site so a suite adds a timeout by
    # calling this and nothing else. Every suite used to print its own row in its own table format,
    # which was the same three lines copied six times.
    printf '\033[0;31mTIMEOUT\033[0m  %s\n' "$test_name"
    echo ""
    echo "========================================================================"
    echo "TIMED OUT: $test_name"
    echo "========================================================================"
    echo "This test was killed after $seconds seconds. It did not fail an assertion,"
    echo "it stopped making progress and was still running when the suite gave up."
    echo ""
    echo "Set PHOTOSPHERE_PER_TEST_TIMEOUT to raise the limit for a genuinely slow test."
    echo ""

    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        echo "Full log: $log_file"
        echo ""
        echo "--- last 40 lines it wrote before it was killed ---"
        tail -40 "$log_file"
        echo "--- end of log ---"
    else
        echo "No log file was written, so there is nothing to show from the test itself."
        echo "That on its own says it stopped before it produced any output."
    fi
    echo "========================================================================"
    echo ""
}
