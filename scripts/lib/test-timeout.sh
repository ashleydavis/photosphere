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
# 600 seconds. The first figure here was 300, taken from a slowest legitimate test of about 75
# seconds measured across the suites on this machine. That measurement was misleading: it came from
# emulators attached to the LAN bridge, where the host is a fast hop away. On the NAT-only emulator
# CI runs, a single step of 41-s3-database-lifecycle was still working at 122 seconds, because every
# part of creating a database on S3 is a round trip to the host and there are hundreds of them. The
# same test takes 24 seconds end to end locally.
#
# So the ceiling has to clear the slowest environment rather than the most convenient one. 600 gives
# a test that needs a few minutes of genuine round trips room to finish, while still being far short
# of the CI job budgets that used to absorb a wedged test in silence.
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
PHOTOSPHERE_PER_TEST_TIMEOUT="${PHOTOSPHERE_PER_TEST_TIMEOUT:-600}"

# Seconds a whole suite of separate tests may run before it is treated as stuck, for suites that pass
# it to start_suite_watchdog. Capping each test is not the same thing: on Git Bash there is no
# timeout(1), so the per-test cap falls back to killing the test's process tree and waiting for it,
# and a kill that does not take leaves that wait blocked for good. The CLI suite normally finishes in
# 15 minutes on windows-latest and has twice run past 27 and 40, so 25 minutes is well clear of a
# slow run and well short of the job budget that used to absorb the hang without a log.
PHOTOSPHERE_SUITE_TIMEOUT="${PHOTOSPHERE_SUITE_TIMEOUT:-1500}"

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

    # Found with type -P and run by its resolved path, so a shell function named `timeout` in a
    # caller cannot be taken for the real command: command -v finds functions, and function lookup
    # beats PATH whatever the check said. Handing GNU's --kill-after to something that expects a
    # bare duration fails instantly and everywhere, so the two extra lines earn their place.
    local timeout_bin
    timeout_bin="$(type -P timeout 2>/dev/null)"
    if [ -z "$timeout_bin" ]; then
        timeout_bin="$(type -P gtimeout 2>/dev/null)"
    fi
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" --kill-after=5 "$seconds" "$@"
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
# Holds a whole script to a ceiling, for the suites that are one script rather than a set of separate
# tests (the sync, write-lock and hash-cache suites). There is no individual test in those to cap, so
# the script itself is the unit, and the ceiling defaults to the per-test timeout to suit them.
#
# A suite made of separate tests passes its own, larger ceiling. Capping each test is not enough for
# those: the CLI suite caps every test at the per-test timeout and still ran 40 minutes past its
# normal 15 on windows-latest, because whatever is stuck there is not inside a test. That run was
# killed by the job timeout, and GitHub discards the log of a job it kills, so the API returns 404
# and the hang left nothing to read at all. A ceiling here fails the suite from the inside instead,
# which ends the step normally and keeps everything the suite had already printed, including the RUN
# line of whichever test never reported back.
#
# The watchdog kills the calling script's children first, so whatever command it is blocked on lets
# go, and then the script itself, which makes the run exit non-zero and fail the suite. It reports
# before killing anything, because after the kill there is nobody left to report.
#
# Its own pid is skipped: the watchdog is a child of the script too and would otherwise be the first
# thing it killed.
#
# Usage: start_suite_watchdog <suite_name> [seconds]   ... then stop_suite_watchdog at the end
#
start_suite_watchdog() {
    local suite_name="$1"
    local ceiling="${2:-$PHOTOSPHERE_PER_TEST_TIMEOUT}"
    # Which variable the reader is told to change has to follow which one is in force here, or the
    # three script-is-the-unit suites that take the default would be pointed at a variable that does
    # not govern them.
    local limit_variable="PHOTOSPHERE_PER_TEST_TIMEOUT"
    if [ -n "${2:-}" ]; then
        limit_variable="PHOTOSPHERE_SUITE_TIMEOUT"
    fi
    local script_pid=$$

    (
        # Polled rather than one long sleep, and the poll checks the script is still alive. These
        # suites already install their own EXIT traps, so a watchdog that relied on being cancelled by
        # one would be left running whenever a script replaced the trap, and would later fire against
        # a pid the kernel had given to something else. Watching for the parent to disappear means it
        # cleans itself up whatever the script does with its traps.
        local waited=0
        while [ "$waited" -lt "$ceiling" ]; do
            if ! kill -0 "$script_pid" 2>/dev/null; then
                exit 0
            fi
            sleep 1
            waited=$((waited + 1))
        done

        report_test_timeout "$suite_name" "$ceiling" "" "$limit_variable" >&2
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
# The fourth argument names the variable that raises the limit, because a suite ceiling and a test
# ceiling are not the same knob and pointing at the wrong one sends the reader to change a number
# that has nothing to do with what they just saw.
#
# Usage: report_test_timeout <test_name> <seconds> <log_file> [limit_variable_name]
#
report_test_timeout() {
    local test_name="$1"
    local seconds="$2"
    local log_file="$3"
    local limit_variable="${4:-PHOTOSPHERE_PER_TEST_TIMEOUT}"

    # The one-line marker lives here rather than at each call site so a suite adds a timeout by
    # calling this and nothing else. Every suite used to print its own row in its own table format,
    # which was the same three lines copied six times.
    printf '\033[0;31mTIMEOUT\033[0m  %s\n' "$test_name"
    echo ""
    echo "========================================================================"
    echo "TIMED OUT: $test_name"
    echo "========================================================================"
    echo "This was killed after $seconds seconds. It did not fail an assertion,"
    echo "it stopped making progress and was still running when the limit was reached."
    echo ""
    echo "Set $limit_variable to raise the limit for a genuinely slow run."
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
