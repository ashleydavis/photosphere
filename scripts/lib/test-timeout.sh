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
# 15 minutes on windows-latest and has run past 27, 40 and 32.
#
# A ceiling only earns its keep if it fires before every cap above it, and those caps differ by job:
# the CLI suite runs under step caps of 14, 24 and 25 minutes across the build jobs, so no single
# number here can sit under all of them. This default suits the jobs whose own caps are above it, and
# a job that needs a lower one sets PHOTOSPHERE_SUITE_TIMEOUT in the workflow beside the caps it has
# to fit inside. `build-windows` does, and the note there says what it cost not to.
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
# The test is started with job control on, so it gets SIGINT and SIGQUIT as a terminal would give
# them. A shell without job control sets both to ignored for every background job it starts, and a
# test started that way passes the ignore on to every command it runs. Nothing below can take it back:
# a shell that finds a signal ignored when it starts may not reset it, so the test's own `set -m` does
# not help. That made Ctrl+C a no-op for `psi dbs send` until the command installed its own handler,
# and 78-dbs-share-cancel waited out the sender's 60 second timeout on macOS, which takes this path.
# With job control on the job leads its own process group, which changes nothing here: the killer
# walks the tree from the pid. Its standard input is /dev/null, which is what the shell gave a
# background job without job control, so no test starts reading a terminal it never read before.
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

    local monitor_was_on="no"
    case "$-" in
        *m*)
            monitor_was_on="yes"
            ;;
    esac
    set -m
    "$@" < /dev/null &
    local child_pid=$!
    if [ "$monitor_was_on" = "no" ]; then
        set +m
    fi
    local timed_out_marker
    timed_out_marker="$(mktemp "${TMPDIR:-/tmp}/photosphere-test-timeout-XXXXXX")"
    rm -f "$timed_out_marker"

    # The killer records its sleep's pid and stops that sleep itself when it is stopped, so the sleep
    # cannot outlive it and expire in its own time. That used to be a `pkill -P` from here, which Git
    # Bash does not have. The killer is stopped below by the pid recorded when it was started, with a
    # plain kill rather than kill_process_tree: its trap takes care of its one child, and a tree walk
    # runs ps for every process it visits, which under load costs seconds on every call.
    #
    # The trap kills "$!" rather than a variable assigned after the `&`. A TERM that arrives just
    # after the sleep is forked runs the trap before that assignment, and a trap reading the variable
    # found it empty and left the sleep running: on Git Bash that happened on most fast calls, because
    # the caller stops the killer as soon as the command returns. $! is set by the fork itself.
    # `sleeping` and the pid inherited from the caller keep the trap from killing anything else: before
    # the fork $! is still the caller's last background job, which is never this killer's to stop.
    (
        inherited_background_pid=$!
        sleeping="no"
        trap 'if [ "$sleeping" = "yes" ] && [ "$!" != "$inherited_background_pid" ]; then kill "$!" 2>/dev/null; fi; exit 0' TERM
        sleeping="yes"
        sleep "$seconds" &
        sleep_pid=$!
        wait "$sleep_pid"
        sleeping="no"
        inherited_background_pid=$!
        # Recorded before the kill, so the marker exists by the time wait returns below.
        : > "$timed_out_marker"
        kill_process_tree "$child_pid"
    ) >/dev/null 2>&1 &
    local killer_pid=$!

    wait "$child_pid"
    local child_status=$?

    kill "$killer_pid" 2>/dev/null || true
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

    # Each poll's sleep is recorded and stopped by the watchdog's own TERM trap, for the same reason
    # as the killer in run_test_with_timeout.
    (
        local inherited_background_pid=$!
        local sleeping="no"
        trap 'if [ "$sleeping" = "yes" ] && [ "$!" != "$inherited_background_pid" ]; then kill "$!" 2>/dev/null; fi; exit 0' TERM
        local started_at=$SECONDS
        while [ "$((SECONDS - started_at))" -lt "$PHOTOSPHERE_PER_TEST_TIMEOUT" ]; do
            if ! kill -0 "$script_pid" 2>/dev/null; then
                exit 0
            fi
            sleeping="yes"
            sleep 1 &
            sleep_pid=$!
            wait "$sleep_pid"
            sleeping="no"
            inherited_background_pid=$!
        done
        : > "$timeout_marker"
        local child
        for child in $(process_children "$script_pid"); do
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
# Watches a whole script and kills it when it is stuck, in one of two ways.
#
# Without a ceiling, for the suites that are one script rather than a set of separate tests (the sync,
# write-lock and hash-cache suites), it is a stall detector. There is no individual test in those to
# cap, and the script's length is not fixed: the sync suite is four workers each running ten
# iterations of six CLI commands, two hundred and forty commands before the final round, and each one
# takes seconds on a loaded Windows machine. Holding that to a total of the per-test timeout killed it
# at 600 seconds part way through its second or third iteration, with every worker still finishing a
# command every few seconds. So the script reports progress by calling suite_progress, and the
# watchdog fires when nothing has been reported for the per-test timeout: the same number, now
# meaning what it says, the point past which nothing is happening any more. A command that hangs
# still fails the suite loudly, because it stops the reports.
#
# A suite made of separate tests passes its own, larger ceiling, which is a limit on the whole run
# however much progress it makes. Capping each test is not enough for
# those: the CLI suite caps every test at the per-test timeout and still ran 40 minutes past its
# normal 15 on windows-latest, because whatever is stuck there is not inside a test. That run was
# killed by the job timeout, and GitHub discards the log of a job it kills, so the API returns 404
# and the hang left nothing to read at all. A ceiling here fails the suite from the inside instead,
# which ends the step normally and keeps everything the suite had already printed, including the RUN
# line of whichever test never reported back.
#
# The watchdog notes the calling script's children, sends the script SIGTERM, and then kills the
# children it noted, so whatever command the script is blocked on lets go and the run exits non-zero
# and fails the suite. The SIGTERM goes first. Killing the children first let the script carry on in
# the gap, since killing a tree waits for it to go: a script blocked on a `sleep` ran its remaining
# commands and exited 0 before the signal reached it, so a timed-out run could pass. Sent first, the
# signal is already pending when the blocking command dies, so a script without a TERM trap is gone
# at once and one with a trap runs it before starting anything else. That trap must end the script:
# one that only cleans up lets the script carry on, which is how the write-lock suite went on
# verifying files after its timeout. The children are noted before
# the signal because a script that dies at once leaves them to be reparented, after which they can
# no longer be found from it. It reports before killing anything, because after the kill there is
# nobody left to report.
#
# Its own pid is skipped: the watchdog is a child of the script too and would otherwise be the first
# thing it killed.
#
# Usage: start_suite_watchdog <suite_name> [seconds]   ... then stop_suite_watchdog at the end
#        suite_progress                               ... whenever a stall-detecting suite moves on
#
start_suite_watchdog() {
    local suite_name="$1"
    local ceiling="${2:-}"
    # Which variable the reader is told to change has to follow which one is in force here, or the
    # three script-is-the-unit suites that take the default would be pointed at a variable that does
    # not govern them.
    local limit_variable="PHOTOSPHERE_PER_TEST_TIMEOUT"
    local limit="$PHOTOSPHERE_PER_TEST_TIMEOUT"
    if [ -n "$ceiling" ]; then
        limit_variable="PHOTOSPHERE_SUITE_TIMEOUT"
        limit="$ceiling"
    fi
    local script_pid=$$

    # Progress is a byte appended to a file, and the watchdog watches the file's length. Appending is
    # safe from every worker subshell at once, and the length needs no stat, whose options differ
    # between GNU and macOS. The name comes from mktemp, so no two runs share one.
    SUITE_PROGRESS_FILE=""
    if [ -z "$ceiling" ]; then
        SUITE_PROGRESS_FILE="$(mktemp "${TMPDIR:-/tmp}/photosphere-suite-progress-XXXXXX")"
    fi
    local progress_file="$SUITE_PROGRESS_FILE"

    (
        # Polled rather than one long sleep, and the poll checks the script is still alive. These
        # suites already install their own EXIT traps, so a watchdog that relied on being cancelled by
        # one would be left running whenever a script replaced the trap, and would later fire against
        # a pid the kernel had given to something else. Watching for the parent to disappear means it
        # cleans itself up whatever the script does with its traps.
        #
        # Measured against the clock rather than by counting iterations. An iteration is a sleep plus
        # a fork, so counting them can only ever overshoot the ceiling, never undershoot it, and this
        # ceiling now has to land inside a window bounded by the caps above it.
        #
        # With a ceiling nothing moves last_progress_at, so the limit runs from the start.
        #
        # Each poll's sleep is recorded and stopped by this TERM trap, so stopping the watchdog never
        # leaves a sleep behind. It used to be stopped with `pkill -P`, which Git Bash does not have.
        local inherited_background_pid=$!
        local sleeping="no"
        trap 'if [ "$sleeping" = "yes" ] && [ "$!" != "$inherited_background_pid" ]; then kill "$!" 2>/dev/null; fi; exit 0' TERM
        local started_at=$SECONDS
        local last_progress_at=$SECONDS
        local last_progress_size=0
        local progress_size
        while [ "$((SECONDS - last_progress_at))" -lt "$limit" ]; do
            if ! kill -0 "$script_pid" 2>/dev/null; then
                if [ -n "$progress_file" ]; then
                    rm -f "$progress_file"
                fi
                exit 0
            fi
            if [ -n "$progress_file" ]; then
                if progress_size="$(wc -c < "$progress_file")"; then
                    progress_size=$((progress_size))
                    if [ "$progress_size" -ne "$last_progress_size" ]; then
                        last_progress_size=$progress_size
                        last_progress_at=$SECONDS
                    fi
                else
                    echo "suite watchdog: cannot read the progress file $progress_file, so $suite_name is counted as making no progress" >&2
                fi
            fi
            sleeping="yes"
            sleep 1 &
            sleep_pid=$!
            wait "$sleep_pid"
            sleeping="no"
            inherited_background_pid=$!
        done

        local summary="This was killed after $((SECONDS - started_at)) seconds, the limit for the whole run."
        if [ -n "$progress_file" ]; then
            summary="This was killed after $((SECONDS - started_at)) seconds, the last $limit of them with no progress reported."
        fi
        report_test_timeout "$suite_name" "$limit" "" "$limit_variable" "$summary" >&2
        local child children
        children="$(process_children "$script_pid")"
        kill -TERM "$script_pid" 2>/dev/null || true
        for child in $children; do
            if [ "$child" = "$BASHPID" ]; then
                continue
            fi
            kill_process_tree "$child"
        done

        # The progress file goes once the script has, not before: its traps still log on the way out,
        # and an append after the removal would make the file again with nobody left to remove it.
        if [ -n "$progress_file" ]; then
            while kill -0 "$script_pid" 2>/dev/null; do
                sleeping="yes"
                sleep 1 &
                sleep_pid=$!
                wait "$sleep_pid"
                sleeping="no"
                inherited_background_pid=$!
            done
            rm -f "$progress_file"
        fi
    ) &
    SUITE_WATCHDOG_PID=$!
}

#
# Tells a stall-detecting watchdog that the suite has moved on, which restarts its clock. A suite
# calls it each time it reports a step, from the script or from any worker it started. It fails, and
# says so, when no stall-detecting watchdog was started, because a suite calling it believes it is
# being watched for stalls and would otherwise be watched for nothing.
# Usage: suite_progress
#
suite_progress() {
    if [ -z "${SUITE_PROGRESS_FILE:-}" ]; then
        echo "suite_progress: no stall-detecting watchdog is running; start one with start_suite_watchdog <suite_name>" >&2
        return 1
    fi
    printf '.' >> "$SUITE_PROGRESS_FILE"
}

#
# Cancels the watchdog started by start_suite_watchdog. Safe to call when none was started.
# Usage: stop_suite_watchdog
#
stop_suite_watchdog() {
    if [ -z "${SUITE_WATCHDOG_PID:-}" ]; then
        return 0
    fi
    # Stopped by its recorded pid; its TERM trap stops its own sleep, which is the only child it has.
    kill "$SUITE_WATCHDOG_PID" 2>/dev/null || true
    wait "$SUITE_WATCHDOG_PID" 2>/dev/null || true
    SUITE_WATCHDOG_PID=""
    if [ -n "${SUITE_PROGRESS_FILE:-}" ]; then
        rm -f "$SUITE_PROGRESS_FILE"
        SUITE_PROGRESS_FILE=""
    fi
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
# The fifth argument replaces the sentence saying what ran out, for a watchdog whose limit is not a
# plain time since the start, so the report says what was actually measured.
#
# Usage: report_test_timeout <test_name> <seconds> <log_file> [limit_variable_name] [summary]
#
report_test_timeout() {
    local test_name="$1"
    local seconds="$2"
    local log_file="$3"
    local limit_variable="${4:-PHOTOSPHERE_PER_TEST_TIMEOUT}"
    local summary="${5:-This was killed after $seconds seconds, the limit for one test.}"

    # The one-line marker lives here rather than at each call site so a suite adds a timeout by
    # calling this and nothing else. Every suite used to print its own row in its own table format,
    # which was the same three lines copied six times.
    printf '\033[0;31mTIMEOUT\033[0m  %s\n' "$test_name"
    echo ""
    echo "========================================================================"
    echo "TIMED OUT: $test_name"
    echo "========================================================================"
    echo "$summary"
    echo "It did not fail an assertion: it was still running when the limit was reached."
    echo ""
    echo "Set $limit_variable to raise the limit for a genuinely slow run."
    echo ""

    if [ -z "$log_file" ]; then
        # The suite watchdog and the function timeout watch tests that write straight to the run's
        # own output, so there is no file to show and everything they printed is already above.
        echo "It wrote to this output rather than to a log file, so what it printed is above."
    elif [ -f "$log_file" ]; then
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
