#!/usr/bin/env bash
#
# usage-begin
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
# before it will call the suite clean. `--force` is always passed, so the change gate never skips a
# suite: every run exercises everything.
#
# The ladder (--ladder) climbs the suites in turn, cheapest first, requiring the full streak of each
# one before it starts the next: the unit tests, then the CLI suite, then Electron, then Android. It
# exists because looping the whole set is the slowest possible way to find a flaky unit test. A unit
# run takes seconds and an Android run takes minutes, so a hundred green unit runs cost a few minutes
# and rule out an entire suite before anything expensive starts. A failure on a low rung is also far
# easier to read than the same failure buried in a parallel run of everything at once, and the ladder
# stops there rather than spending hours on the rungs above it.
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
# A sick Android emulator pool is treated the same way, and only when the looped command actually
# drives the emulators (`test:and` and the whole set do; unit tests, the CLI suite, the Electron
# suite and the iOS suite do not). The loop pauses instead of failing: it says the pool is sick and
# waits for it to come back, keeping the streak. Restart the emulators and the session carries on by
# itself, with however many devices come back. It gives up only after DEVICE_WAIT_SECONDS of waiting,
# or after DEVICE_FAILURE_RETRIES runs in a row have gone red with a sick pool.
#
# Every run is timed, and before each one the loop prints when that run should end and when the whole
# streak should. The estimate is the mean of the last few runs rather than of all of them, so it exists
# from the second run onwards, tightens as the session goes on, and follows a machine that gets slower
# or faster part way through instead of staying anchored to how the session began. It counts time spent
# running only: a pause waiting for an emulator pool, or a crash that is retried, pushes the real
# finish later than the estimate says.
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
#   bun run find-flakey-tests -- --ladder
#       Climb every suite in turn, cheapest first, requiring the full streak of each before starting
#       the next. The first rung to fail stops the session.
#
#   bun run find-flakey-tests -- --ladder "test test:cli test:ios"
#       Climb the rungs you name instead of the default ones, in the order you name them.
#
#   bun run find-flakey-tests -- --script test:and --test 19
#       Loop a single test within a suite. The filter is passed straight through to the suite, so
#       whatever that suite accepts works here: a number, part of a name, or a full directory name.
#
#   bun run find-flakey-tests -- --command "bun run test -- describe-http-error"
#       Loop any command at all. Use this for anything the options above do not cover.
#
#   bun run find-flakey-tests -- --target 500
#       Require a 500-run streak instead of the default 100.
#
#   bun run find-flakey-tests -- --resume 4
#       Carry on from an earlier session that banked 4 green runs. The next run is numbered 5.
#
#   bun run find-flakey-tests -- --help
#
# Options:
#
#   --script NAME "everything" (the default) runs `bun run test:everything -- --force`, the whole
#                 set. Otherwise name any one suite that the whole set runs; give a name it does not
#                 know and it prints the ones it does. Looping a single suite is much faster per run,
#                 so when failures are concentrated in one suite it surfaces them several times
#                 sooner. The cost is coverage: a single-suite streak says nothing about the others.
#
#   --ladder [L]  climb the suites in turn, requiring a full --target streak of each one before
#                 starting the next, and stopping the session at the first rung that fails. With no
#                 list it climbs every suite the pre-commit hook runs on this platform, cheapest
#                 first. Give a list (space or comma separated, from the same names as --script) to
#                 climb your own rungs, which is how to include test:ios on macOS or to climb a
#                 handful rather than all of them. Cannot be combined with --script, --test or
#                 --command, since each of those names a single thing to loop.
#
#   --test FILTER narrow to one test within the chosen suite, for example `--script test:and --test 19`.
#                 Requires --script. Use this once a particular test is known to be the flaky one:
#                 a single mobile test takes seconds where the whole suite takes minutes.
#
#   --target N    consecutive green runs required before the suite is declared clean (default 100).
#                 On a ladder it is the streak required of every rung, not of the ladder as a whole.
#
#   --resume N    carry on from a session that banked N green runs (default 0): those N count towards
#                 the target and the next run is numbered N+1, so the numbering and the streak can
#                 never drift apart. For resuming after an interruption that was not a test failure,
#                 for example stopping to restart an emulator pool or a machine reboot. Only sound
#                 when the code under test has not changed since those runs passed: a streak is only
#                 meaningful as N runs of one tree. A test failure resets the count to zero and no
#                 flag should be used to paper over that. On a ladder it applies to the first rung
#                 only, the one the session restarts on; the rungs above it start from zero as they
#                 always would. That is the form the session prints when it stops part way up.
#
#   --command C   loop this exact command. Overrides --script and --test, and takes whatever you give
#                 it, so it can run anything: one unit test, a script that is not a test, a command
#                 with its own arguments. The harness's own tests use it to drive the loop against
#                 commands with known outcomes.
#
#   --help        print this usage and exit.
#
# Output: everything is written under tmp/find-flakey-tests/<timestamp>/ in the repo (gitignored),
# one log per run plus a report.txt on failure. A ladder puts each rung's run logs in its own
# subdirectory named after the suite, so one rung's logs never write over another's. The paths are
# printed as the last lines of stdout.
#
# Exit status: 0 when the target streak is reached, 1 when a run failed, 2 on bad usage, 3 when too
# many consecutive Bun crashes made the result meaningless, 4 when the Android emulator pool the
# looped command depends on stopped being healthy and did not come back.
# usage-end
#
set -uo pipefail

# Repo root, resolved from this script's location so it works from any working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Consecutive green runs required before the suite is declared clean.
TARGET=100

# Green runs already banked before this invocation, counted towards the target, with the run
# numbering carrying on from them. Lets a streak survive an interruption that was not a test failure
# (a pool restart, a reboot), which otherwise makes a long target unreachable: every interruption
# would send the count back to zero.
#
# One number rather than two. There used to be a separate flag for the run numbering, and giving only
# that one looked exactly like resuming while banking nothing: a session was restarted at run 83 and
# quietly began its streak again from zero.
RESUME=0

# The command driven in a loop. `--force` defeats the change gate so every suite runs every time,
# which is the whole point: a gated run can skip the very suite that is flaky.
COMMAND="bun run test:everything -- --force"

# Which suite --script selects. Kept as a list so an unknown name is rejected with the valid ones
# named, rather than failing later as a missing bun script.
#
# The rule for what belongs here: every suite `bun run test:everything -- --force` runs, so that any
# suite the pre-commit hook can refuse a commit over is a suite this script can loop and prove sound.
# `compile` is not here because it is a build rather than a suite, and looping it says nothing about
# flakiness. When a new suite is added to the whole set, add it here too.
SCRIPT_CHOICES="everything test test:cli test:cli:encrypted test:cli:lan-share test:cli:sync test:cli:write-lock test:cli:hash-cache test:electron test:lan-share:cli-desktop test:harness test:and test:and:unit test:ios test:ios:unit"

# The suite chosen by --script, and a filter within it from --test. Kept separate from COMMAND
# because the two are combined only after both have been parsed, so the order of the options on the
# command line does not matter.
SCRIPT=""
TEST_FILTER=""

# Whether --command was given. --command wins over --script, and this records that it was an explicit
# choice rather than the default sitting in COMMAND.
COMMAND_GIVEN=0

# Whether --ladder was given, and the rungs it climbs in the order they are climbed.
#
# The default rungs are the suites in increasing cost order, which is also increasing order of how
# much a failure costs to read: a red unit run names a test in seconds, a red Android run is minutes
# of emulator output. test:ios and test:ios:unit are not among them because most of this work happens
# on Linux, where those rungs can never pass; name them explicitly on macOS, for example
# `--ladder "test test:cli test:ios"`.
#
# Every suite the pre-commit hook runs is a rung, so a green climb covers what a commit is judged
# against. When a new suite is added to the whole set, add it here too.
LADDER=0
LADDER_RUNGS=""
LADDER_DEFAULT="test:cli:hash-cache test:lan-share:cli-desktop test:and:unit test:harness test:cli:write-lock test test:cli:sync test:cli:encrypted test:cli:lan-share test:cli test:electron test:and"

# The rung being climbed, named in every run line and in the failure report so a log read afterwards
# says which suite each run belonged to. Empty when a single command is being looped.
RUNG_LABEL=""

# The rungs left to climb, the one in progress included, so a session that stops part way up can say
# how to carry on from there rather than from the bottom.
REMAINING_RUNGS=""

# How many Bun runtime crashes in a row are tolerated before giving up. One crash is bad luck and is
# retried; a run of them means something is genuinely broken and continuing would hide it.
BUN_CRASH_RETRIES=5

# Text that identifies a crash of the Bun runtime itself, as opposed to a test failure. Matched
# against the run's whole output.
BUN_CRASH_PATTERN="Bun has crashed|panic: |terminated by signal SIG(ILL|SEGV|BUS|ABRT)|Segmentation fault"

# How often a paused loop re-checks a sick emulator pool, in seconds. Short enough that a restarted
# pool is picked up promptly, long enough that the polling is not itself a load on the machine.
DEVICE_POLL_SECONDS=30

# How often the paused loop says it is still waiting, in seconds.
DEVICE_REPORT_SECONDS=300

# How long the loop waits for a sick pool to come back before giving up, in seconds. Long enough to
# notice the pause and restart a pool by hand, short enough that an unattended overnight run does not
# sit paused until morning with nothing to show for it.
DEVICE_WAIT_SECONDS=3600

# How many runs in a row may go red with a sick pool before giving up. Each one is waited out rather
# than counted as a failure, which is right for a pool that dies once, but a pool that dies during
# every run would otherwise keep the loop going forever without ever banking a green.
DEVICE_FAILURE_RETRIES=5

# How many of the most recent runs the time estimate averages over. Few enough that it follows a
# machine whose speed changes part way through a session, which is normal here: a background build
# finishing, an emulator pool being restarted at a different size, the per-test temp tree growing.
# Many enough that one unusually slow run does not throw the whole estimate.
ESTIMATE_WINDOW=10

# Prints the usage block at the top of this file, so there is one copy of it rather than two.
print_usage() {
    # Delimited by sentinel lines rather than by hardcoded line numbers, which is what this used to
    # do: the range went stale as the header grew and silently dropped --target out of the help.
    sed -n '/^# usage-begin$/,/^# usage-end$/p' "${BASH_SOURCE[0]}" \
        | sed '1d;$d' \
        | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="${2:-}"
            shift 2
            ;;
        --resume)
            RESUME="${2:-}"
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
        --ladder)
            LADDER=1
            # The rung list is optional, so the next argument is only taken when there is one and it
            # is not another option. Without that check, `--ladder --target 20` would swallow
            # `--target` as the list and then complain about a rung called "--target".
            case "${2:-}" in
                ''|--*)
                    shift
                    ;;
                *)
                    LADDER_RUNGS="$2"
                    shift 2
                    ;;
            esac
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
    local reply index=1 choice selection=""
    echo "Which suite should be looped?"
    for choice in $SCRIPT_CHOICES ladder; do
        case "$choice" in
            everything)
                echo "  $index) everything    the whole set (bun run test:everything -- --force)"
                ;;
            ladder)
                echo "  $index) ladder        each suite in turn, cheapest first: $LADDER_DEFAULT"
                ;;
            *)
                echo "  $index) $choice"
                ;;
        esac
        index=$((index + 1))
    done
    printf "Choose [1]: "
    read -r reply
    reply="${reply:-1}"

    index=1
    for choice in $SCRIPT_CHOICES ladder; do
        if [ "$index" = "$reply" ]; then
            selection="$choice"
        fi
        index=$((index + 1))
    done
    if [ -z "$selection" ]; then
        echo "find-flakey-tests: '$reply' is not one of the choices." >&2
        exit 2
    fi

    if [ "$selection" = "ladder" ]; then
        LADDER=1
    else
        SCRIPT="$selection"
    fi

    if [ -n "$SCRIPT" ] && [ "$SCRIPT" != "everything" ]; then
        printf "Narrow to one test? (a number or part of a name, blank for all): "
        read -r TEST_FILTER
    fi

    if [ "$LADDER" -eq 1 ]; then
        printf "How many consecutive green runs of each suite? [%s]: " "$TARGET"
    else
        printf "How many consecutive green runs? [%s]: " "$TARGET"
    fi
    read -r reply
    TARGET="${reply:-$TARGET}"
}

if [ "$COMMAND_GIVEN" -eq 0 ] && [ -z "$SCRIPT" ] && [ "$LADDER" -eq 0 ] && [ -t 0 ]; then
    prompt_for_selection
fi

# A ladder loops several commands one after another, so the options that name a single thing to loop
# have nothing to say about it. Rejected rather than quietly ignored: a run given both would otherwise
# do something other than what either option asked for.
if [ "$LADDER" -eq 1 ]; then
    if [ "$COMMAND_GIVEN" -eq 1 ] || [ -n "$SCRIPT" ] || [ -n "$TEST_FILTER" ]; then
        echo "find-flakey-tests: --ladder cannot be combined with --script, --test or --command; each of those loops one thing, and a ladder loops several in turn." >&2
        exit 2
    fi

    LADDER_RUNGS="${LADDER_RUNGS:-$LADDER_DEFAULT}"

    # Commas are accepted as well as spaces, because a list of suite names reads naturally either way
    # and getting it wrong would otherwise fail as an unknown rung called "test,test:cli".
    LADDER_RUNGS="${LADDER_RUNGS//,/ }"

    rung_count=0
    for rung in $LADDER_RUNGS; do
        case " $SCRIPT_CHOICES " in
            *" $rung "*) ;;
            *)
                echo "find-flakey-tests: --ladder rungs must each be one of: $SCRIPT_CHOICES (got '$rung')" >&2
                exit 2
                ;;
        esac
        rung_count=$((rung_count + 1))
    done

    if [ "$rung_count" -eq 0 ]; then
        echo "find-flakey-tests: --ladder was given an empty list of rungs." >&2
        exit 2
    fi

    REMAINING_RUNGS="$LADDER_RUNGS"
fi

#
# Writes the command that loops one named suite. The whole set is the one that needs more than its
# script name: `--force` defeats the change gate, without which a looped run would skip whichever
# suites have not changed, which could be the very one that is flaky.
#
# Usage: command_for_script <script_name>
#
command_for_script() {
    local script="$1"

    if [ "$script" = "everything" ]; then
        echo "bun run test:everything -- --force"
    else
        echo "bun run $script"
    fi
}

# --command wins outright. Otherwise a chosen suite becomes the command, with any --test filter
# appended, and with nothing chosen at all the default set in COMMAND above stands.
if [ "$COMMAND_GIVEN" -eq 0 ] && [ -n "$SCRIPT" ]; then
    COMMAND="$(command_for_script "$SCRIPT")"
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
case "$RESUME" in
    ''|*[!0-9]*)
        echo "find-flakey-tests: --resume must be a whole number, got '$RESUME'" >&2
        exit 2
        ;;
esac
if [ "$TARGET" -lt 1 ]; then
    echo "find-flakey-tests: --target must be at least 1" >&2
    exit 2
fi

# A resume that already meets the target would run nothing at all and declare the suite clean on the
# strength of runs from another session, which is the one thing this loop must never do.
if [ "$RESUME" -ge "$TARGET" ]; then
    echo "find-flakey-tests: --resume $RESUME already meets --target $TARGET, so there would be nothing to run. Raise --target." >&2
    exit 2
fi

# Everything this session writes lives here. Under tmp/, which is gitignored, and stamped with the
# start time so a new session never writes over an older one's evidence.
SESSION_DIR="$ROOT/tmp/find-flakey-tests/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION_DIR"

REPORT="$SESSION_DIR/report.txt"

# Per-test temporary directories, for the count reported at the end of a session.
source "$ROOT/scripts/lib/allocate-test-temp-dir.sh"

# How many per-test directories existed before this session started, so the growth it causes can be
# told from what was already there.
TEST_TEMP_COUNT_AT_START="$(photosphere_test_temp_count)"

#
# Reports how much the tree of per-test directories grew over this session.
#
# Nothing removes those directories, so a session that runs the suite hundreds of times leaves
# hundreds of them behind and the tree grows without bound. That growth once turned a 15 second run
# into a 46 second one, and the cause was invisible until somebody went looking. Printing the count
# at the end of every session means it shows up on the session that caused it.
#
report_test_temp_growth() {
    local count_now
    count_now="$(photosphere_test_temp_count)"
    echo "Per-test temp directories under $PHOTOSPHERE_TEST_TEMP_ROOT: $count_now"
    echo "  (was $TEST_TEMP_COUNT_AT_START at the start of this session; nothing removes them.)"
}

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
# Reports whether every attached Android emulator is still answering, printing a reason and returning
# non-zero for the first one that is not. Says nothing about how many devices there are, which is the
# caller's business.
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
# loop waits them out rather than carrying on, because every run made against a sick pool produces
# failures that say nothing about the code and each one resets the streak.
#
# This only ever reads. It does not start, stop, reconnect or otherwise touch a device: recovering
# the pool is a person's job, and an earlier attempt to poke a device from here is exactly the kind
# of thing that should not happen from inside a loop.
#
# Usage: check_devices_responding
#
check_devices_responding() {
    local serial

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

#
# Reports whether the pool is still the one the loop started with: the same number of devices, every
# one of them answering. Prints a reason and returns non-zero when it is not.
#
# Usage: check_devices_healthy <expected_count>
#
check_devices_healthy() {
    local expected="$1"
    local attached

    attached="$(adb devices 2>/dev/null | grep -c "device$")"
    if [ "$attached" -ne "$expected" ]; then
        echo "device count changed: started with $expected, now $attached" >&2
        return 1
    fi

    check_devices_responding
}

#
# Waits for a sick emulator pool to come back, returning non-zero if it has not within
# DEVICE_WAIT_SECONDS. Sets DEVICE_COUNT_AT_START to the size of the pool it resumes with.
#
# The loop pauses rather than stops, because a sick pool says nothing about the code under test.
# Stopping throws away a streak that took hours to build, over something a person can put right in a
# minute once they are told the loop is waiting on it. The streak is not touched while paused, so the
# session carries on from exactly where it was.
#
# Whatever comes back may be a different size to what went away, so the count is re-baselined here
# rather than held to the old number: an operator restarting a pool may well bring up fewer or more
# emulators than before, and holding out for the old number would wait forever. The Android suite
# discovers its devices at the start of every run (apps/smoke-tests/run.sh), so a smaller pool means
# the same tests spread over fewer devices, not tests queueing for devices that are never coming.
#
# Like the check itself, this only ever reads. Restarting emulators is a person's job.
#
# Usage: wait_for_healthy_devices
#
wait_for_healthy_devices() {
    local waited=0 attached

    while [ "$waited" -lt "$DEVICE_WAIT_SECONDS" ]; do
        sleep "$DEVICE_POLL_SECONDS"
        waited=$((waited + DEVICE_POLL_SECONDS))

        # A pool of nothing is not a pool: with no devices attached at all there is nothing for the
        # suite to run on, so that counts as still waiting.
        attached="$(adb devices 2>/dev/null | grep -c "device$")"
        if [ "$attached" -gt 0 ] && check_devices_responding 2>/dev/null; then
            if [ "$attached" -eq "$DEVICE_COUNT_AT_START" ]; then
                echo "  pool is answering again after $((waited / 60))m, $attached device(s). Resuming."
            else
                echo "  pool is answering again after $((waited / 60))m, now $attached device(s) instead of $DEVICE_COUNT_AT_START. Resuming."
            fi
            DEVICE_COUNT_AT_START="$attached"
            return 0
        fi

        # Only every few minutes: a line every poll would bury the reason it paused in the first
        # place, which is the one thing worth reading here.
        if [ "$((waited % DEVICE_REPORT_SECONDS))" -eq 0 ]; then
            echo "  still waiting for the emulator pool, $((waited / 60))m of $((DEVICE_WAIT_SECONDS / 60))m"
        fi
    done

    return 1
}

#
# Prints where the streak got to and how to carry it on, then stops with the infrastructure exit
# status. Reads the loop's counters, so it is only meaningful once the loop is running.
#
# Usage: stop_for_sick_pool <reason>
#
stop_for_sick_pool() {
    local reason="$1"

    echo
    echo "find-flakey-tests: STOPPING, $reason"
    echo "The streak stands at $greens of $TARGET. Nothing here changed anything on any device."
    if [ -n "$RUNG_LABEL" ]; then
        # The rungs below this one are already proven on this tree, so the way back in is the rest of
        # the ladder with this rung's banked runs carried over, not the whole ladder from the bottom.
        echo "Restart the pool, then carry on with: --ladder \"$REMAINING_RUNGS\" --target $TARGET --resume $greens"
    else
        echo "Restart the pool, then carry on with: --resume $greens"
    fi
    echo "LOGS=$SESSION_DIR"
    exit 4
}

#
# Writes a number of seconds as a short duration, the largest two units of it only, because the
# estimate is never precise enough for the seconds in "2h 14m 09s" to mean anything.
#
# Usage: format_duration <seconds>
#
format_duration() {
    local total="$1"
    local hours=$((total / 3600))
    local minutes=$(( (total % 3600) / 60 ))
    local seconds=$((total % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%dh %02dm' "$hours" "$minutes"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm %02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

#
# Writes an absolute time, given as seconds since the epoch, in the given date format. GNU date's
# spelling first, BSD date's second, since this repository is developed on both Linux and macOS.
#
# Usage: format_epoch <epoch_seconds> <date_format>
#
format_epoch() {
    local epoch="$1"
    local format="$2"

    date -d "@$epoch" "+$format" 2>/dev/null || date -r "$epoch" "+$format"
}

#
# Writes an absolute time, given as seconds since the epoch, as a clock time. A time on a later day
# carries the day with it, because a long streak finishing "at 06:15" is ambiguous about which
# morning is meant and these sessions routinely run overnight.
#
# Usage: format_clock_time <epoch_seconds>
#
format_clock_time() {
    local epoch="$1"

    if [ "$(format_epoch "$epoch" '%Y-%m-%d')" = "$(date '+%Y-%m-%d')" ]; then
        format_epoch "$epoch" '%H:%M:%S'
    else
        format_epoch "$epoch" '%a %d %b %H:%M'
    fi
}

#
# Recalculates the expected length of a run from the runs that have already finished, into
# estimate_seconds and estimate_sample. Both stay at zero while there is nothing to estimate from.
#
# Only the last ESTIMATE_WINDOW runs are averaged, so the estimate tracks the machine as it is now
# rather than as it was at the start of the session.
#
# Usage: update_estimate
#
update_estimate() {
    local index total=0 count=0

    index=$(( ${#run_durations[@]} - ESTIMATE_WINDOW ))
    if [ "$index" -lt 0 ]; then
        index=0
    fi

    while [ "$index" -lt "${#run_durations[@]}" ]; do
        total=$((total + run_durations[index]))
        count=$((count + 1))
        index=$((index + 1))
    done

    if [ "$count" -eq 0 ]; then
        estimate_seconds=0
        estimate_sample=0
        return
    fi

    estimate_seconds=$(( (total + count / 2) / count ))
    estimate_sample="$count"
}

#
# Prints when the run about to start should end and when the whole streak should, or says there is
# nothing to estimate from yet.
#
# Printed before the run rather than after it, because the run itself puts every line it produces in
# its log file: from the terminal, a run in progress is a single header line and a long silence, and
# the only useful thing to say during that silence is when it will be over.
#
# The numbers count time spent running. A pause waiting for a sick emulator pool, or a crashed run
# that is retried, puts the real finish later than this.
#
# Usage: print_estimate
#
print_estimate() {
    local now remaining run_end streak_seconds streak_end

    if [ "$estimate_sample" -eq 0 ]; then
        echo "  no estimate yet, the first run makes one."
        return
    fi

    now="$(date +%s)"
    remaining=$((TARGET - greens))
    run_end=$((now + estimate_seconds))
    streak_seconds=$((estimate_seconds * remaining))
    streak_end=$((now + streak_seconds))

    echo "  $(format_duration "$estimate_seconds") a run over the last $estimate_sample: this run ends about $(format_clock_time "$run_end")"
    echo "  $remaining run(s) left, all green about $(format_clock_time "$streak_end"), $(format_duration "$streak_seconds") from now"
}

#
# Reports whether a command actually drives Android devices, which decides whether the emulator pool
# is watched while that command loops. Only the Android smoke suite talks to adb, and only `test:and`
# and the whole set include it. Everything else (the unit tests, the CLI suite, the Electron suite,
# the iOS suite) touches no Android device, so an emulator going bad on the machine has nothing to do
# with the run and must not interrupt the streak.
#
# This is not hypothetical: a `bun run test` streak was halted at 84 of 100 by an emulator that run
# never went near, because the check keyed off "any device is attached" rather than "this command
# uses the devices".
#
# Usage: command_drives_devices <command>
#
command_drives_devices() {
    local command="$1"

    # The patterns end at the name so `test:and:unit`, which is Gradle unit tests and needs no
    # device, is not mistaken for the device-driving `test:and`.
    case "$command" in
        *test:and|*"test:and "*|*test:everything|*"test:everything "*)
            return 0
            ;;
    esac

    return 1
}

# Consecutive green runs so far on the streak in progress, including any banked by a previous
# invocation on the same tree.
greens="$RESUME"

# The number given to the run currently being performed. Runs are numbered by where they sit in the
# streak, so run N is the Nth green run if it passes, and a resumed session carries straight on.
run_number=$((RESUME + 1))

# The number of the first run of the streak in progress, for the summary at the end.
first_run_number="$run_number"

# Consecutive Bun crashes, reset by any run that does not crash.
consecutive_crashes=0

# Every Bun crash seen this session, reported at the end so they are never silently swallowed. Kept
# across a whole ladder rather than per rung, because a machine that crashes Bun on two different
# rungs is one problem and has to be readable as one.
crash_runs=()

# Consecutive red runs blamed on a sick emulator pool, reset by any run that passes.
consecutive_device_failures=0

# Every run this session that went red with a sick pool, reported at the end for the same reason as
# the crashes: a run that was not counted is still a run that has to be visible.
device_failure_runs=()

# How long each green run of the streak in progress took, in seconds, oldest first. Only green runs,
# because a run that crashed or died on a sick pool was cut short or dragged out by something that is
# not the suite, and letting either into the average would make every estimate after it wrong.
run_durations=()

# The expected length of a run in seconds, and how many runs that expectation is drawn from. Zero
# until the first run finishes, which is the only time the loop has nothing to estimate from.
estimate_seconds=0
estimate_sample=0

# How many devices were attached when the streak in progress started. The check compares against this
# rather than a fixed number, so it works whatever size the pool is, and is skipped entirely when
# there are none (a streak of unit tests or the CLI suite needs no device).
DEVICE_COUNT_AT_START=0

# How long the streak in progress took, in seconds, filled in when it finishes.
streak_duration=0

#
# Loops one command until TARGET consecutive green runs are banked, and returns only on success: a
# real failure writes the report and stops the whole session from in here, because the point of the
# loop is the streak and a streak with a failure in it is not a streak.
#
# The counters it works on are the globals above rather than locals, because the failure paths print
# them, the summary at the end prints them again, and on a ladder the crash and sick-pool lists have
# to survive from one rung to the next.
#
# Usage: run_streak <command> <run_directory> <green_runs_already_banked>
#
run_streak() {
    COMMAND="$1"
    local run_dir="$2"
    local resume_from="$3"
    local streak_start run_label run_log run_start run_status run_duration crash_line device_failure_line

    mkdir -p "$run_dir"

    # Worked out per streak rather than once per session, because a ladder loops a different command
    # on every rung: the unit rung must not watch the emulators and the Android rung must.
    DEVICE_COUNT_AT_START=0
    if command_drives_devices "$COMMAND"; then
        DEVICE_COUNT_AT_START="$(adb devices 2>/dev/null | grep -c "device$")"
    fi
    if [ "$DEVICE_COUNT_AT_START" -gt 0 ]; then
        echo "find-flakey-tests: $DEVICE_COUNT_AT_START device(s) attached. The loop pauses if that changes or one stops answering."
    fi

    greens="$resume_from"
    run_number=$((resume_from + 1))
    first_run_number="$run_number"
    consecutive_crashes=0
    consecutive_device_failures=0

    # Reset for each streak. Durations from an earlier rung say nothing about this one: a unit run
    # takes seconds where an Android run takes minutes, so carrying them over would make every
    # estimate on the new rung badly wrong for as long as the window took to fill.
    run_durations=()
    estimate_seconds=0
    estimate_sample=0

    streak_start="$(date +%s)"

    echo "find-flakey-tests: requiring $TARGET consecutive green runs of: $COMMAND"
    if [ "$resume_from" -gt 0 ]; then
        echo "find-flakey-tests: resuming with $resume_from green run(s) banked, numbering from run $((resume_from + 1))."
    fi
    echo "find-flakey-tests: logs in $run_dir"
    echo

    while [ "$greens" -lt "$TARGET" ]; do
        # Wait rather than run against a pool that has degraded. The streak is kept while waiting, so
        # restarting the emulators is all it takes to have the session carry on. The count is zero,
        # and this whole check therefore skipped, unless the looped command drives the devices.
        if [ "$DEVICE_COUNT_AT_START" -gt 0 ] && ! check_devices_healthy "$DEVICE_COUNT_AT_START"; then
            echo
            echo "find-flakey-tests: PAUSED because the emulator pool is not healthy."
            echo "The streak of $greens of $TARGET is kept. Nothing here changed anything on any device."
            echo "Restart the pool and the loop picks it up by itself, waiting up to $((DEVICE_WAIT_SECONDS / 60))m."
            if ! wait_for_healthy_devices; then
                stop_for_sick_pool "the emulator pool did not come back within $((DEVICE_WAIT_SECONDS / 60))m."
            fi
            echo
        fi

        run_label="$(printf '%04d' "$run_number")"
        run_log="$run_dir/run-$run_label.log"
        run_start="$(date +%s)"

        echo "===== ${RUNG_LABEL:+$RUNG_LABEL }run $run_number (green $greens of $TARGET) ====="
        print_estimate
        mise exec -- bash -c "$COMMAND" > "$run_log" 2>&1
        run_status=$?
        run_duration="$(( $(date +%s) - run_start ))"

        if [ "$run_status" -eq 0 ]; then
            greens=$((greens + 1))
            consecutive_crashes=0
            consecutive_device_failures=0
            run_durations+=("$run_duration")
            update_estimate
            echo "  PASS in $(format_duration "$run_duration") (green $greens of $TARGET)"
            run_number=$((run_number + 1))
            continue
        fi

        # A crash of the Bun runtime is not a failure of the code under test, so it does not break
        # the streak. It is retried under the same run number and always reported.
        if grep -qE "$BUN_CRASH_PATTERN" "$run_log"; then
            consecutive_crashes=$((consecutive_crashes + 1))
            crash_runs+=("${RUNG_LABEL:+$RUNG_LABEL }run $run_number (${run_duration}s): $run_log")
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

        # A red run made against a pool that is now sick says nothing about the code: the devices the
        # tests needed stopped answering underneath them. Treated like a Bun crash rather than a
        # failure, so it does not break the streak: the pool is waited on and the run number retried.
        if [ "$DEVICE_COUNT_AT_START" -gt 0 ] && ! check_devices_healthy "$DEVICE_COUNT_AT_START"; then
            consecutive_device_failures=$((consecutive_device_failures + 1))
            device_failure_runs+=("${RUNG_LABEL:+$RUNG_LABEL }run $run_number (${run_duration}s): $run_log")
            echo "  FAIL in ${run_duration}s, but the emulator pool is sick, so it is not counted (device failure $consecutive_device_failures of $DEVICE_FAILURE_RETRIES allowed in a row)"
            if [ "$consecutive_device_failures" -ge "$DEVICE_FAILURE_RETRIES" ]; then
                stop_for_sick_pool "$consecutive_device_failures runs in a row went red with a sick emulator pool, so waiting it out is getting nowhere."
            fi
            echo "find-flakey-tests: PAUSED. Restart the pool and the loop picks it up by itself, waiting up to $((DEVICE_WAIT_SECONDS / 60))m."
            if ! wait_for_healthy_devices; then
                stop_for_sick_pool "the emulator pool did not come back within $((DEVICE_WAIT_SECONDS / 60))m."
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
            if [ -n "$RUNG_LABEL" ]; then
                echo "ladder rung:    $RUNG_LABEL, of: $LADDER_RUNGS"
            fi
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

        SUITE_LOGS="$run_dir/suite-logs-run-$run_label"
        if snapshot_suite_logs "$SUITE_LOGS"; then
            echo "suite logs:     $SUITE_LOGS" >> "$REPORT"
        fi

        cat "$REPORT"
        echo
        if [ -n "$RUNG_LABEL" ]; then
            # A failed streak starts again from zero, so there is nothing to resume; what is worth
            # keeping is the rungs below this one, which are already proven clean on this tree.
            echo "The rungs below $RUNG_LABEL are clean. Once this is fixed, carry on from here with:"
            echo "  bun run find-flakey-tests -- --ladder \"$REMAINING_RUNGS\" --target $TARGET"
            echo
        fi
        if [ "${#crash_runs[@]}" -gt 0 ]; then
            echo "Bun crashes earlier in this session (not counted as failures):"
            for crash_line in "${crash_runs[@]}"; do
                echo "  $crash_line"
            done
            echo
        fi
        if [ "${#device_failure_runs[@]}" -gt 0 ]; then
            echo "Runs earlier in this session that went red with a sick emulator pool (not counted as failures):"
            for device_failure_line in "${device_failure_runs[@]}"; do
                echo "  $device_failure_line"
            done
            echo
        fi
        report_test_temp_growth
        echo
        echo "REPORT=$REPORT"
        echo "RUN_LOG=$run_log"
        echo "LOGS=$SESSION_DIR"
        exit 1
    done

    streak_duration="$(( $(date +%s) - streak_start ))"
}

session_start="$(date +%s)"

# What each rung of a ladder proved, one line each, for the summary at the end. A ladder that reached
# the top has to show what it actually did rung by rung: "everything is clean" says nothing about how
# much of it was run or how long each part took.
ladder_results=()

if [ "$LADDER" -eq 1 ]; then
    echo "find-flakey-tests: climbing the ladder: $LADDER_RUNGS"
    echo "find-flakey-tests: $TARGET consecutive green runs of each rung, cheapest first, stopping at the first rung that fails."
    if [ "$RESUME" -gt 0 ]; then
        echo "find-flakey-tests: resuming the first rung with $RESUME green run(s) banked; the rungs above it start from zero."
    fi
    echo "find-flakey-tests: logs in $SESSION_DIR"
    echo

    rung_index=0

    for rung in $LADDER_RUNGS; do
        RUNG_LABEL="$rung"
        rung_index=$((rung_index + 1))

        # Each rung's logs go in their own directory, because every streak numbers its runs from one
        # and a shared directory would have the Android rung's run-0001.log write over the unit
        # rung's. Numbered as well as named, so the directory listing is in the order they were
        # climbed and a rung named twice does not write over itself. The suite name carries a colon,
        # which is legal in a path but awkward to type, so it becomes a dash.
        run_streak "$(command_for_script "$rung")" "$SESSION_DIR/$(printf '%02d' "$rung_index")-${rung//:/-}" "$RESUME"

        ladder_results+=("$rung: $TARGET green run(s) in $(format_duration "$streak_duration")")
        echo
        echo "find-flakey-tests: rung $rung is clean, $TARGET green runs in $(format_duration "$streak_duration")."
        echo

        # Only the rung the session starts on can inherit banked runs. Every rung above it has not
        # been run at all on this tree, so it starts from zero however the session was invoked.
        RESUME=0

        # The rungs still to climb, this one now behind us, so a failure higher up says how to carry
        # on from exactly where it stopped rather than from the bottom of the ladder.
        REMAINING_RUNGS="${REMAINING_RUNGS#"$rung"}"
        REMAINING_RUNGS="${REMAINING_RUNGS# }"
    done
else
    run_streak "$COMMAND" "$SESSION_DIR" "$RESUME"
fi

session_duration="$(( $(date +%s) - session_start ))"

echo
if [ "$LADDER" -eq 1 ]; then
    echo "find-flakey-tests: every rung of the ladder is clean, $TARGET consecutive green runs each."
    for ladder_line in "${ladder_results[@]}"; do
        echo "  $ladder_line"
    done
    echo "Total $(format_duration "$session_duration")."
else
    echo "find-flakey-tests: $TARGET consecutive green runs, no failures."
    echo "Runs $first_run_number to $((run_number - 1)), total $(format_duration "$session_duration"), $(format_duration "$estimate_seconds") a run at the end."
fi
if [ "${#crash_runs[@]}" -gt 0 ]; then
    echo
    echo "Bun crashes seen and retried (not counted as failures):"
    for crash_line in "${crash_runs[@]}"; do
        echo "  $crash_line"
    done
fi
if [ "${#device_failure_runs[@]}" -gt 0 ]; then
    echo
    echo "Runs that went red with a sick emulator pool and were retried (not counted as failures):"
    for device_failure_line in "${device_failure_runs[@]}"; do
        echo "  $device_failure_line"
    done
fi
echo
report_test_temp_growth
echo "LOGS=$SESSION_DIR"
exit 0
