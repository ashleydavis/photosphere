#!/usr/bin/env bash
#
# Runs the full test suite over and over to prove it is not flaky, and stops dead at the first
# failure with everything needed to diagnose it.
#
# This solves no single flaky failure. It is the instrument that finds them: every entry in
# the flaky-test notes added on or after 2026-08-02 was found by running this, and the
# report it writes on failure (failing lane and test, snapshotted per-test logs, machine state) is
# what made each of them diagnosable rather than a timeout with no cause attached.
#
# The premise is that a suite which passes once tells you very little. A mode that fails one run in
# two hundred will pass any normal check and still break a build later. This drives
# `bun run test:everything -- --force` in a loop and requires a long unbroken streak of green runs
# before it will call the suite clean. `--force` is always passed, so the what-changed gate never
# skips a suite: every run exercises everything.
#
# On the first real failure it bails out rather than carrying on, because the point of the loop is
# the streak, and a streak with a failure in it is not a streak. It then writes a diagnosis report
# naming the lane and the test that failed, quoting the tail of the run's output, snapshotting the
# suite-side log files that the next run would otherwise overwrite, and recording the state of the
# machine (memory, attached devices, recent kernel out-of-memory kills), because several of the
# failure modes this loop has found were caused by the machine rather than by the code.
#
# Bun runtime crashes are treated separately. A SIGSEGV or SIGILL inside Bun itself is not a failure
# of the code under test, so such a run is retried rather than counted, up to BUN_CRASH_RETRIES times
# in a row. Every crash is still reported in the summary, so they can never pass unnoticed.
#
# Usage:
#
#   bun run find-flakey-tests
#       With no arguments and a terminal attached, it asks which suite to loop and how long a streak
#       to require. This is the normal way to run it by hand.
#
#   bun run find-flakey-tests -- --script test:and
#       Loop one suite instead of the whole set.
#
#   bun run find-flakey-tests -- --script test:and --test 19
#       Loop a single test within a suite. The filter is passed straight through to the suite, so
#       whatever that suite accepts works here: a number, part of a name, or a full directory name.
#
#   bun run find-flakey-tests -- --command "bun run test -- describe-http-error"
#       Loop any command at all. Use this for anything the options above do not cover.
#
#   bun run find-flakey-tests -- --target 100
#       Require a 100-run streak instead of the default 500.
#
#   bun run find-flakey-tests -- --greens 4 --start 5
#       Carry on from an earlier session: 4 runs already banked, number the next run 5.
#
#   bun run find-flakey-tests -- --help
#
# Options:
#
#   --script NAME one of: everything (default), test, test:cli, test:electron, test:and, test:ios.
#                 "everything" runs `bun run test:everything -- --force`, the whole set. The others
#                 run that one suite. Looping a single suite is much faster per run, so when failures
#                 are concentrated in one suite it surfaces them several times sooner. The cost is
#                 coverage: a single-suite streak says nothing about the others.
#
#   --test FILTER narrow to one test within the chosen suite, for example `--script test:and --test 19`.
#                 Requires --script. Use this once a particular test is known to be the flaky one:
#                 a single mobile test takes seconds where the whole suite takes minutes.
#
#   --target N    consecutive green runs required before the suite is declared clean (default 500).
#
#   --start N     the run number to label the first run with (default 1). Purely cosmetic: it affects
#                 the numbering in the log and the report, not how many runs are performed. Use it
#                 when continuing a session so the run numbers carry on from where they left off.
#
#   --greens N    green runs already banked, counted towards the target (default 0). For resuming
#                 after an interruption that was not a test failure, for example stopping to restart
#                 an emulator pool or a machine reboot. Only sound when the code under test has not
#                 changed since those runs passed: a streak is only meaningful as N runs of one tree.
#                 A test failure resets the count to zero and no flag should be used to paper over
#                 that.
#
#   --command C   loop this exact command. Overrides --script and --test, and takes whatever you give
#                 it, so it can run anything: one unit test, a script that is not a test, a command
#                 with its own arguments. The harness's own tests use it to drive the loop against
#                 commands with known outcomes.
#
#   --help        print this usage and exit.
#
# Output: everything is written under tmp/find-flakey-tests/<timestamp>/ in the repo (gitignored),
# one log per run plus a report.txt on failure. The paths are printed as the last lines of stdout.
#
# Exit status: 0 when the target streak is reached, 1 when a run failed, 2 on bad usage, 3 when too
# many consecutive Bun crashes made the result meaningless.
#
set -uo pipefail

# Repo root, resolved from this script's location so it works from any working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Consecutive green runs required before the suite is declared clean.
TARGET=500

# The number given to the first run. Cosmetic only, for continuing a previous session's numbering.
START=1

# Green runs already banked before this invocation, counted towards the target. Lets a streak
# survive an interruption that was not a test failure (a pool restart, a reboot), which otherwise
# makes a long target unreachable: every interruption would send the count back to zero.
GREENS=0

# The command driven in a loop. `--force` defeats the what-changed gate so every suite runs every
# time, which is the whole point: a gated run can skip the very suite that is flaky.
COMMAND="bun run test:everything -- --force"

# Which suite --script selects. Kept as a list so an unknown name is rejected with the valid ones
# named, rather than failing later as a missing bun script.
SCRIPT_CHOICES="everything test test:cli test:electron test:and test:ios"

# The suite chosen by --script, and a filter within it from --test. Kept separate from COMMAND
# because the two are combined only after both have been parsed, so the order of the options on the
# command line does not matter.
SCRIPT=""
TEST_FILTER=""

# Whether --command was given. --command wins over --script, and this records that it was an explicit
# choice rather than the default sitting in COMMAND.
COMMAND_GIVEN=0

# How many Bun runtime crashes in a row are tolerated before giving up. One crash is bad luck and is
# retried; a run of them means something is genuinely broken and continuing would hide it.
BUN_CRASH_RETRIES=5

# Text that identifies a crash of the Bun runtime itself, as opposed to a test failure. Matched
# against the run's whole output.
BUN_CRASH_PATTERN="Bun has crashed|panic: |terminated by signal SIG(ILL|SEGV|BUS|ABRT)|Segmentation fault"

# Prints the usage block at the top of this file, so there is one copy of it rather than two.
print_usage() {
    # The range ends at the last line of the header comment block, which is the line before
    # `set -uo pipefail`. Update it if the header grows: a stale range silently truncates the
    # help, which is how --target once vanished from it.
    sed -n '3,89p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="${2:-}"
            shift 2
            ;;
        --start)
            START="${2:-}"
            shift 2
            ;;
        --greens)
            GREENS="${2:-}"
            shift 2
            ;;
        --script)
            SCRIPT="${2:-}"
            case " $SCRIPT_CHOICES " in
                *" $SCRIPT "*) ;;
                *)
                    echo "find-flakey-tests: --script must be one of: $SCRIPT_CHOICES (got '$SCRIPT')" >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --test)
            TEST_FILTER="${2:-}"
            shift 2
            ;;
        --command)
            COMMAND="${2:-}"
            COMMAND_GIVEN=1
            shift 2
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "find-flakey-tests: unknown option '$1'" >&2
            echo "Try: bun run find-flakey-tests -- --help" >&2
            exit 2
            ;;
    esac
done

# Asks which suite to loop and how long a streak to require.
#
# Only reached when the script is run by hand with no selection given. A background or scripted run
# passes --script or --command and never sees this, and the terminal check below means a run with no
# terminal attached falls through to the default rather than blocking for input that can never come.
prompt_for_selection() {
    local reply index=1 choice
    echo "Which suite should be looped?"
    for choice in $SCRIPT_CHOICES; do
        if [ "$choice" = "everything" ]; then
            echo "  $index) everything    the whole set (bun run test:everything -- --force)"
        else
            echo "  $index) $choice"
        fi
        index=$((index + 1))
    done
    printf "Choose [1]: "
    read -r reply
    reply="${reply:-1}"

    index=1
    for choice in $SCRIPT_CHOICES; do
        if [ "$index" = "$reply" ]; then
            SCRIPT="$choice"
        fi
        index=$((index + 1))
    done
    if [ -z "$SCRIPT" ]; then
        echo "find-flakey-tests: '$reply' is not one of the choices." >&2
        exit 2
    fi

    if [ "$SCRIPT" != "everything" ]; then
        printf "Narrow to one test? (a number or part of a name, blank for all): "
        read -r TEST_FILTER
    fi

    printf "How many consecutive green runs? [%s]: " "$TARGET"
    read -r reply
    TARGET="${reply:-$TARGET}"
}

if [ "$COMMAND_GIVEN" -eq 0 ] && [ -z "$SCRIPT" ] && [ -t 0 ]; then
    prompt_for_selection
fi

# --command wins outright. Otherwise a chosen suite becomes the command, with any --test filter
# appended, and with nothing chosen at all the default set in COMMAND above stands.
if [ "$COMMAND_GIVEN" -eq 0 ] && [ -n "$SCRIPT" ]; then
    if [ "$SCRIPT" = "everything" ]; then
        COMMAND="bun run test:everything -- --force"
    else
        COMMAND="bun run $SCRIPT"
    fi
fi

if [ -n "$TEST_FILTER" ]; then
    if [ "$COMMAND_GIVEN" -eq 1 ]; then
        echo "find-flakey-tests: --test cannot be combined with --command; put the filter in the command itself." >&2
        exit 2
    fi
    if [ -z "$SCRIPT" ] || [ "$SCRIPT" = "everything" ]; then
        echo "find-flakey-tests: --test needs --script naming a single suite (got '${SCRIPT:-none}')." >&2
        exit 2
    fi
    COMMAND="$COMMAND $TEST_FILTER"
fi

# Both numbers have to be positive integers, checked here rather than producing a confusing failure
# thousands of runs later or an infinite loop.
case "$TARGET" in
    ''|*[!0-9]*)
        echo "find-flakey-tests: --target must be a positive whole number, got '$TARGET'" >&2
        exit 2
        ;;
esac
case "$START" in
    ''|*[!0-9]*)
        echo "find-flakey-tests: --start must be a positive whole number, got '$START'" >&2
        exit 2
        ;;
esac
case "$GREENS" in
    ''|*[!0-9]*)
        echo "find-flakey-tests: --greens must be a whole number, got '$GREENS'" >&2
        exit 2
        ;;
esac
if [ "$TARGET" -lt 1 ]; then
    echo "find-flakey-tests: --target must be at least 1" >&2
    exit 2
fi

# Everything this session writes lives here. Under tmp/, which is gitignored, and stamped with the
# start time so a new session never writes over an older one's evidence.
SESSION_DIR="$ROOT/tmp/find-flakey-tests/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION_DIR"

REPORT="$SESSION_DIR/report.txt"

# Records the state of the machine at the moment of a failure. Several failure modes found by this
# loop were nothing to do with the code: the kernel's out-of-memory killer taking an Android
# emulator, and an emulator vanishing mid-test. Neither is visible in the suite's own output, and
# both are obvious here.
capture_machine_state() {
    echo "--- machine state at failure ---"
    echo "date: $(date -Is)"

    if command -v free >/dev/null 2>&1; then
        echo "memory:"
        free -h 2>&1 | sed 's/^/  /'
    fi

    if command -v adb >/dev/null 2>&1; then
        echo "attached devices:"
        adb devices 2>&1 | sed 's/^/  /'
    fi

    # An out-of-memory kill explains a whole suite failing at once and leaves no trace in the suite's
    # own logs, so it is worth looking for explicitly.
    if command -v journalctl >/dev/null 2>&1; then
        local oom_lines
        oom_lines="$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -iE "oom-kill|Out of memory: Killed" | tail -5)"
        if [ -n "$oom_lines" ]; then
            echo "kernel out-of-memory kills in the last hour:"
            echo "$oom_lines" | sed 's/^/  /'
        else
            echo "kernel out-of-memory kills in the last hour: none"
        fi
    fi
}

# Pulls the interesting lines out of a failed run's output: which parallel lane failed, which named
# tests failed, and where their logs are. The suite prints these in a stable form, so a failure can
# be summarised without anyone having to read thousands of lines of build output.
summarise_failure() {
    local log_file="$1"

    echo "--- failing lanes ---"
    grep -E "^\s+FAIL\s+bun run|error: script .* exited with code" "$log_file" | sed 's/^/  /' || echo "  (none matched)"

    echo
    echo "--- failing tests ---"
    # Not anchored to the start of the line, because the suite colours these and the line therefore
    # begins with an escape sequence rather than the word. Anchoring it meant the first failure this
    # script caught reported "2 of 37 tests failed" without naming either of them.
    grep -aE "FAIL.*\(log:|tests? failed" "$log_file" | sed 's/^/  /' || echo "  (none matched)"

    echo
    echo "--- last 60 lines of the run ---"
    tail -60 "$log_file" | sed 's/^/  /'
}

# Copies the per-test log files the mobile smoke suite writes under its own tmp dirs. The runner
# clears those before each test, so without this they are gone the moment the next run starts.
snapshot_suite_logs() {
    local destination="$1"
    local found=0
    local log_file relative_path target_dir

    while IFS= read -r log_file; do
        relative_path="${log_file#"$ROOT"/}"
        target_dir="$destination/$(dirname "$relative_path")"
        mkdir -p "$target_dir"
        cp "$log_file" "$target_dir/"
        found=1
    done < <(find "$ROOT/apps/smoke-tests/tests" "$ROOT/apps/desktop/smoke-tests" -path '*/tmp/*' -name '*.log' -type f 2>/dev/null)

    return $((1 - found))
}

#
# Reports whether the Android emulators are still in the state the loop started with, printing a
# reason and returning non-zero when they are not.
#
# "Degraded" here means one of four things actually seen during this work, all of which produced a
# red test that had nothing to do with the code under test:
#
#   1. An emulator process crashes and the device disappears from adb entirely.
#   2. A device stays listed by adb but its system services have gone, so the very first thing a test
#      does fails with "cmd: Can't find service: package".
#   3. The app starts and then hangs, reported by Android as an ANR, and never connects.
#   4. Fewer devices are attached than when the loop started, so tests queue for devices that are
#      never coming back and the run takes many times its normal length.
#
# The first two are checked here, because they are cheap and unambiguous to check between runs. The
# loop stops on them rather than carrying on, because every run after that point produces failures
# that say nothing about the code and each one resets the streak.
#
# This only ever reads. It does not start, stop, reconnect or otherwise touch a device: recovering
# the pool is a person's job, and an earlier attempt to poke a device from here is exactly the kind
# of thing that should not happen from inside a loop.
#
# Usage: check_devices_healthy <expected_count>
#
check_devices_healthy() {
    local expected="$1"
    local attached serial

    attached="$(adb devices 2>/dev/null | grep -c "device$")"
    if [ "$attached" -ne "$expected" ]; then
        echo "device count changed: started with $expected, now $attached" >&2
        return 1
    fi

    for serial in $(adb devices 2>/dev/null | grep "device$" | cut -f1); do
        if ! timeout 30 adb -s "$serial" shell "cmd package list packages" 2>/dev/null | grep -q "^package:"; then
            echo "$serial is attached but its package manager service is not answering" >&2
            return 1
        fi

        # Whether the guest can still reach the host. Every mobile test depends on this: the app
        # talks to the host's control bridge over the LAN bridge, so a device that cannot reach the
        # host fails every test assigned to it while adb still reports it as present and healthy.
        #
        # This is not hypothetical. One emulator lost its route to the host while keeping its wlan0
        # address, its services and its adb connection. Five of the next six failures landed on that
        # one device, each costing a full run and a diagnosis, because nothing noticed it was unable
        # to do the one thing every test needs.
        if ! timeout 30 adb -s "$serial" shell "ping -c 1 -W 2 192.168.55.1" >/dev/null 2>&1; then
            echo "$serial is attached but cannot reach the host at 192.168.55.1" >&2
            return 1
        fi
    done

    return 0
}

# How many devices were attached when the loop started. The check compares against this rather than a
# fixed number, so it works whatever size the pool is, and is skipped entirely when there are no
# devices (a run of unit tests or the CLI suite needs none).
DEVICE_COUNT_AT_START="$(adb devices 2>/dev/null | grep -c "device$")"
if [ "$DEVICE_COUNT_AT_START" -gt 0 ]; then
    echo "find-flakey-tests: $DEVICE_COUNT_AT_START device(s) attached. The loop stops if that changes or one stops answering."
fi

echo "find-flakey-tests: requiring $TARGET consecutive green runs of: $COMMAND"
echo "find-flakey-tests: logs in $SESSION_DIR"
echo

# Consecutive green runs so far, including any banked by a previous invocation on the same tree.
greens="$GREENS"

# The number given to the run currently being performed.
run_number="$START"

# Consecutive Bun crashes, reset by any run that does not crash.
consecutive_crashes=0

# Every Bun crash seen this session, reported at the end so they are never silently swallowed.
crash_runs=()

session_start="$(date +%s)"

while [ "$greens" -lt "$TARGET" ]; do
    # Stop rather than run against a pool that has degraded. Exit 4 marks it as an infrastructure
    # halt, distinct from a test failure (1), so a stopped streak is never mistaken for a red test.
    if [ "$DEVICE_COUNT_AT_START" -gt 0 ] && ! check_devices_healthy "$DEVICE_COUNT_AT_START"; then
        echo
        echo "find-flakey-tests: STOPPING because the emulator pool is no longer healthy."
        echo "The streak stands at $greens of $TARGET. Nothing here changed anything on any device."
        echo "Restart the pool, then resume with: --greens $greens --start $run_number"
        echo "LOGS=$SESSION_DIR"
        exit 4
    fi

    run_label="$(printf '%04d' "$run_number")"
    run_log="$SESSION_DIR/run-$run_label.log"
    run_start="$(date +%s)"

    echo "===== run $run_number (green $greens of $TARGET) ====="
    mise exec -- bash -c "$COMMAND" > "$run_log" 2>&1
    run_status=$?
    run_duration="$(( $(date +%s) - run_start ))"

    if [ "$run_status" -eq 0 ]; then
        greens=$((greens + 1))
        consecutive_crashes=0
        echo "  PASS in ${run_duration}s (green $greens of $TARGET)"
        run_number=$((run_number + 1))
        continue
    fi

    # A crash of the Bun runtime is not a failure of the code under test, so it does not break the
    # streak. It is retried under the same run number and always reported.
    if grep -qE "$BUN_CRASH_PATTERN" "$run_log"; then
        consecutive_crashes=$((consecutive_crashes + 1))
        crash_runs+=("run $run_number (${run_duration}s): $run_log")
        echo "  BUN CRASH in ${run_duration}s, not counted, retrying (crash $consecutive_crashes of $BUN_CRASH_RETRIES allowed in a row)"
        if [ "$consecutive_crashes" -ge "$BUN_CRASH_RETRIES" ]; then
            echo
            echo "find-flakey-tests: $consecutive_crashes Bun crashes in a row; stopping, because a result built on that many crashes would mean nothing."
            echo "Crash logs:"
            for crash_line in "${crash_runs[@]}"; do
                echo "  $crash_line"
            done
            echo "LOGS=$SESSION_DIR"
            exit 3
        fi
        continue
    fi

    # A real failure. Everything below is about making it diagnosable.
    echo "  FAIL in ${run_duration}s (exit $run_status)"
    echo

    {
        echo "find-flakey-tests failure report"
        echo "================================"
        echo
        echo "command:        $COMMAND"
        echo "failed on run:  $run_number"
        echo "green streak:   $greens consecutive passes before this failure"
        echo "target:         $TARGET"
        echo "exit status:    $run_status"
        echo "run duration:   ${run_duration}s"
        echo "session:        $SESSION_DIR"
        echo "full run log:   $run_log"
        echo
        summarise_failure "$run_log"
        echo
        capture_machine_state
    } > "$REPORT"

    SUITE_LOGS="$SESSION_DIR/suite-logs-run-$run_label"
    if snapshot_suite_logs "$SUITE_LOGS"; then
        echo "suite logs:     $SUITE_LOGS" >> "$REPORT"
    fi

    cat "$REPORT"
    echo
    if [ "${#crash_runs[@]}" -gt 0 ]; then
        echo "Bun crashes earlier in this session (not counted as failures):"
        for crash_line in "${crash_runs[@]}"; do
            echo "  $crash_line"
        done
        echo
    fi
    echo "REPORT=$REPORT"
    echo "RUN_LOG=$run_log"
    echo "LOGS=$SESSION_DIR"
    exit 1
done

session_duration="$(( $(date +%s) - session_start ))"

echo
echo "find-flakey-tests: $TARGET consecutive green runs, no failures."
echo "Runs $START to $((run_number - 1)), total ${session_duration}s."
if [ "${#crash_runs[@]}" -gt 0 ]; then
    echo
    echo "Bun crashes seen and retried (not counted as failures):"
    for crash_line in "${crash_runs[@]}"; do
        echo "  $crash_line"
    done
fi
echo "LOGS=$SESSION_DIR"
exit 0
