#!/usr/bin/env bash
#
# Measures whether the Android smoke tests lose emulator memory they never give back.
#
# The symptom being chased: running the Android tests repeatedly makes the pool emulators grow until
# they are throttled and then killed. That is what stops
# `bun run find-flakey-tests -- --script test:and --target 100` from ever finishing: each emulator
# has an 8G allowance, and if it grows by a few hundred megabytes every run it runs out long before a
# hundred runs are done.
#
# A single before-and-after reading cannot tell a leak from start-up cost that settles, so this runs a
# test over and over and reports what each run added. Growth that keeps coming is a leak; growth that
# fades is warm-up. `--all` does that for every test in turn and says which ones leak.
#
# What is measured, and why it is not the obvious thing:
#
#   Resident set size is useless here. The pool emulators are allowed to swap (MemorySwapMax=2G), so
#   RSS drops by hundreds of megabytes when the kernel pages an idle emulator out and climbs again
#   when it is touched. Watching RSS shows a sawtooth that says nothing about leaking.
#
#   memory.current is useless too, for the reason set out in emulator-health.sh: it counts page
#   cache, cache grows to fill whatever it is allowed, and a healthy emulator therefore sits near
#   100% of its limit forever.
#
#   What is counted is `anon` from the control group's memory.stat plus memory.swap.current.
#   Anonymous memory cannot be reclaimed, so it is the part that actually runs an emulator out of
#   room, and adding the swapped-out part back means a page moving to swap does not look like memory
#   being freed. That sum is the number that only goes up when something leaks.
#
# The whole control group is read rather than the emulator's main process, because an emulator is a
# tree of processes and the main one accounts for only part of what it costs.
#
# This script never starts, stops, restarts or otherwise touches an emulator. The pool belongs to
# whoever is at the keyboard. If the pool is not up it says so and stops, rather than helpfully
# bringing it up: a leak measured across a restart is not a measurement of anything, because a
# restarted emulator starts from zero again and hides the very thing being looked for.
#
# Usage:
#
#   bun run measure-android-leak
#       Run test 2-create-database twenty times and report whether it leaks.
#
#   bun run measure-android-leak -- --test 44
#       Any test. The filter matches the way the suite's own filter does: a number, part of a name,
#       or a full directory name.
#
#   bun run measure-android-leak -- --all
#       Every test in turn, with a verdict for each and a worst-first table at the end. This is how
#       to find which tests leak rather than confirming one that is suspected.
#
#   bun run measure-android-leak -- --all --resume-from 26-receive-database
#       Carry on a sweep that stopped because the pool filled up, after restarting the pool.
#
#   bun run measure-android-leak -- --full
#       Run the whole suite each time instead of one test. This matches what find-flakey-tests
#       actually does, and is the configuration that showed the largest growth per run.
#
#   bun run measure-android-leak -- --runs 40
#       More runs per test. Longer sessions give a straighter line and a firmer verdict.
#
#   bun run measure-android-leak -- --detail
#       Also report what is growing inside each emulator: heap, threads, open files, and whether the
#       kernel has started throttling it. The total says a leak exists; this says what kind it is and
#       therefore where to go and look.
#
#   bun run measure-android-leak -- --to-the-end
#       Keep going until an emulator is actually killed by the leak, rather than for a set number of
#       runs. This is what proves the leak matters rather than merely exists: it puts a number on how
#       many runs the pool survives, which is the number that has to beat 100.
#
#   bun run measure-android-leak -- --csv <path>
#       Write the readings somewhere other than the default under the repository's tmp directory.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$REPO_DIR/apps/smoke-tests/tests"

# The AVD names the pool runs under. Sourced rather than copied so a rename cannot leave this script
# quietly matching nothing and reporting an empty pool.
source "$REPO_DIR/apps/android-frontend/scripts/emulator-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# How many times to run each test, and whether that came from the command line. A sweep uses fewer
# runs per test than a single-test session, because it has to fit dozens of tests into the headroom
# one pool has; an explicit --runs overrides both defaults.
RUNS=0
RUNS_GIVEN="false"
DEFAULT_RUNS_SINGLE=20
DEFAULT_RUNS_SWEEP=6

# Which test to measure. 2-create-database is the one measured so far and the only one confirmed to
# grow the pool.
TEST_FILTER="2"

# Measure every test in turn, and where to pick up a sweep that stopped early.
SWEEP_ALL="false"
RESUME_FROM=""

# Run the whole suite instead of a single test when set.
RUN_FULL_SUITE="false"

# Where the readings and the suite's own output are written.
CSV_PATH="$REPO_DIR/tmp/android-emulator-leak.csv"
RUN_LOG_PATH="$REPO_DIR/tmp/android-emulator-leak-runs.log"

# One shared layout for the table header and every row in it, so the two cannot drift apart. They
# were written as separate format strings once and the columns did not line up.
#
# Every field is left-aligned. Right-aligning the numbers put a ragged left edge on the columns:
# "baseline", "+28M" and "+1902M" all ended together but began in three different places, so the eye
# had nothing to run down. Reading which run cost the most is what the growth blocks beside the
# number are for.
TABLE_FORMAT="%-8s %-7s %-22s %-4s %-10s %-21s %s\n"

# Width of the bar showing how full the pool is, drawn against the pool's whole allowance. One block
# covers a lot of memory so the bar barely moves between runs, which is honest: it answers how much
# room is left, and the growth blocks beside it answer whether memory is still being lost.
POOL_BAR_WIDTH=20

# How much memory one growth block stands for, and how many are drawn before the bar is clamped. A
# fixed scale rather than one fitted to the session, so a bar in the last row means the same as a bar
# in the first and the column can be read down by eye.
GROWTH_BLOCK_BYTES=$(( 100 * 1048576 ))
GROWTH_BAR_MAX=20

# Growth below this per run is noise rather than a leak. Emulators move by a few tens of megabytes
# between readings whatever is done to them, and calling that a leak would report one every session.
SETTLED_FLOOR_BYTES=$(( 20 * 1048576 ))

# How full the pool may get before a sweep gives up. Past this the emulators are being throttled and
# reclaiming under pressure, so what a test appears to cost says more about the state of the pool
# than about the test. Carrying on would fill the worst-first table with numbers that mean nothing.
POOL_STOP_PERCENT=85

# The emulators being watched, fixed at the start of the session. See main for why this is not
# re-read as the session goes on.
MEASURE_AVDS=()

# One emulator's allowance, and that allowance times the number of emulators.
PER_EMULATOR_LIMIT=0
POOL_CEILING=0

# Per-test state, reset by start_test before each test is measured.
BASELINE_TOTAL=0
PREVIOUS_TOTAL=0
COMPLETED_RUNS=0
FAILED_RUNS=0
declare -a RUN_DELTAS=()
declare -A FIRST_READING=()
declare -A LATEST_READING=()

# Emulators that have stopped answering, and the names of any that stopped during the run just taken.
#
# This is the end state the leak produces, so it has to be called out rather than absorbed. An
# emulator that has died contributes nothing to the total, so the pool's figure falls by several
# gigabytes the moment it goes: without this the graph shows the largest drop of the session at the
# exact point the pool collapsed, which reads as memory being handed back.
declare -A DEAD_AVDS=()
DIED_THIS_RUN=""

# Run until the pool breaks rather than for a set number of runs. Capped, because "until it breaks"
# has to terminate even when nothing does break.
RUN_TO_THE_END="false"
RUNS_CAP=500

# Report what is growing inside each emulator, not just how much.
#
# The total says a leak exists. It cannot say what is leaking, and the answer changes what to go and
# look at: heap growing on its own is memory the emulator allocated and never freed, file descriptors
# growing is handles never closed, threads growing is tasks never joined. Each points somewhere
# different, and without this the only way to tell them apart was by hand with /proc open in another
# terminal.
DETAIL="false"

# Each emulator's first and latest heap size, thread count and open file count, keyed by AVD name.
# Collected only when DETAIL is set, since reading smaps means walking every mapping of a process
# with thousands of them.
declare -A FIRST_HEAP=()
declare -A LATEST_HEAP=()
declare -A FIRST_THREADS=()
declare -A LATEST_THREADS=()
declare -A FIRST_FDS=()
declare -A LATEST_FDS=()

# Each emulator's reading from the previous run, so the detail rows can show what that one emulator
# added rather than only where it now stands.
declare -A PREVIOUS_PER_EMULATOR=()

# The verdict for the test just measured. Set by classify_verdict and read by whichever reporter is
# in use: the single-test session prints it as prose, the sweep prints it as one line per test.
VERDICT_CLASS=""
VERDICT_AVERAGE=0
VERDICT_FIRST_HALF=0
VERDICT_SECOND_HALF=0
VERDICT_FIRST_COUNT=0
VERDICT_SECOND_COUNT=0

# One line per measured test, as "<average bytes>|<test>|<class>", for the worst-first table a sweep
# prints at the end.
declare -a SWEEP_RESULTS=()

# The first run of any test pays for things no later run repeats: installing the app, starting it for
# the first time, bringing up a WebView. It is always much the largest and proves nothing, so it is
# shown but left out of every average and out of the verdict.
WARMUP_RUNS=1

#
# Prints a byte count as gigabytes to one decimal place.
#
format_gigabytes() {
    awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1073741824 }'
}

#
# Prints a byte count as megabytes, rounded, with a leading sign. Used for changes, where the sign
# carries the meaning and a decimal place does not.
#
format_megabytes_signed() {
    awk -v bytes="$1" 'BEGIN { printf "%+d", bytes / 1048576 }'
}

#
# Prints a byte count as megabytes, rounded, unsigned.
#
format_megabytes() {
    awk -v bytes="$1" 'BEGIN { printf "%d", bytes / 1048576 }'
}

#
# Prints a path relative to the repository when it is inside it. Absolute paths are long enough to
# wrap the terminal and push the columns out of line, and they are meaningless on anyone else's
# machine when the output is pasted somewhere.
#
format_repo_path() {
    echo "${1#"$REPO_DIR"/}"
}

#
# Prints the bar showing how full the pool is: <filled> blocks padded to POOL_BAR_WIDTH with dots.
#
render_pool_bar() {
    local filled="$1"
    local bar=""
    local index

    if [ "$filled" -lt 0 ]; then
        filled=0
    fi
    if [ "$filled" -gt "$POOL_BAR_WIDTH" ]; then
        filled="$POOL_BAR_WIDTH"
    fi

    for (( index = 0; index < filled; index++ )); do
        bar="$bar#"
    done
    for (( index = filled; index < POOL_BAR_WIDTH; index++ )); do
        bar="$bar."
    done

    echo "[$bar]"
}

#
# Prints one run's growth as blocks of GROWTH_BLOCK_BYTES each.
#
# A run that added nothing prints "-", and one that added less than a whole block prints "." rather
# than nothing at all: an empty cell reads as a reading that failed to happen, when what it means is
# a run too small to draw. A run too big for the bar ends in ">", so a clamped bar cannot be mistaken
# for one that merely reached the end.
#
render_growth_blocks() {
    local bytes="$1"
    local blocks bar=""
    local index

    if [ "$bytes" -le 0 ]; then
        echo "-"
        return 0
    fi

    blocks=$(( bytes / GROWTH_BLOCK_BYTES ))
    if [ "$blocks" -eq 0 ]; then
        echo "."
        return 0
    fi
    if [ "$blocks" -gt "$GROWTH_BAR_MAX" ]; then
        for (( index = 0; index < GROWTH_BAR_MAX; index++ )); do
            bar="$bar#"
        done
        echo "$bar>"
        return 0
    fi

    for (( index = 0; index < blocks; index++ )); do
        bar="$bar#"
    done
    echo "$bar"
}

#
# Prints the names of the pool AVDs that are running, one per line.
#
# pgrep's output is captured before anything is matched against it, rather than piped straight into
# grep. In a pipeline the two run at the same time, and pgrep -f matches on whole command lines, so
# it found the sibling grep whose own arguments contained the search pattern and reported a phantom
# emulator named after the pattern itself. The digits are required (+, not *) for the same reason:
# without that, the phantom line still yielded a name with no number on the end.
#
running_pool_avds() {
    local matches

    matches="$(pgrep -a -f -- "-avd $POOL_AVD_PREFIX-" 2>/dev/null || true)"
    if [ -z "$matches" ]; then
        return 0
    fi

    echo "$matches" \
        | grep -oE -- "-avd $POOL_AVD_PREFIX-[0-9]+" \
        | awk '{ print $2 }' \
        | sort -u
}

#
# Prints the control group directory holding one emulator's processes, or nothing when it cannot be
# found.
#
# The path is checked for the pool's own unit name before it is accepted. An emulator started outside
# this project sits in whatever group its shell is in, and reading that group would credit the
# emulator with everything else in the same terminal, which would look exactly like a leak.
#
cgroup_dir_for_avd() {
    local avd="$1"
    local pid cgroup_path

    pid="$(pgrep -f -- "-avd $avd" 2>/dev/null | head -1)"
    if [ -z "$pid" ]; then
        return 0
    fi

    cgroup_path="$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup" 2>/dev/null)"
    case "$cgroup_path" in
        *psphere-emu-*) ;;
        *) return 0 ;;
    esac

    if [ -d "/sys/fs/cgroup$cgroup_path" ]; then
        echo "/sys/fs/cgroup$cgroup_path"
    fi
}

#
# Prints one emulator's unreclaimable memory in bytes: anonymous memory plus whatever has been pushed
# out to swap. Prints nothing when it cannot be read, so an emulator that has died is left out of the
# total rather than counted as zero, which would read as memory being handed back.
#
emulator_memory_bytes() {
    local avd="$1"
    local cgroup_dir anon swap

    cgroup_dir="$(cgroup_dir_for_avd "$avd")"
    if [ -z "$cgroup_dir" ] || [ ! -d "$cgroup_dir" ]; then
        return 0
    fi

    anon="$(awk '/^anon /{ print $2 }' "$cgroup_dir/memory.stat" 2>/dev/null || true)"
    swap="$(cat "$cgroup_dir/memory.swap.current" 2>/dev/null || true)"

    case "$anon" in
        ''|*[!0-9]*) return 0 ;;
    esac
    case "$swap" in
        ''|*[!0-9]*) swap=0 ;;
    esac

    echo $(( anon + swap ))
}

#
# Prints one emulator's memory allowance in bytes. Falls back to the machine's total memory when the
# group has no limit set, so the graph still has a scale rather than dividing by zero.
#
emulator_limit_bytes() {
    local avd="$1"
    local cgroup_dir limit

    cgroup_dir="$(cgroup_dir_for_avd "$avd")"
    if [ -n "$cgroup_dir" ] && [ -d "$cgroup_dir" ]; then
        limit="$(cat "$cgroup_dir/memory.high" 2>/dev/null || true)"
        case "$limit" in
            ''|*[!0-9]*) ;;
            *) echo "$limit"; return 0 ;;
        esac
    fi

    awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo
}

#
# Prints the process id of one emulator's main process, or nothing when it is not running.
#
emulator_main_pid() {
    pgrep -f -- "-avd $1" 2>/dev/null | head -1
}

#
# Prints the size of one emulator's heap in bytes, or nothing when it cannot be read.
#
# The heap's Size rather than its Rss, for the same reason the totals use anonymous memory: these
# emulators swap, so Rss falls when a page is paged out and says nothing about whether the memory was
# freed. A heap only ever grows as far as its Size is concerned, so Size climbing run after run is
# memory the process asked for and never gave back.
#
# This was the figure that localised the leak last time: roughly 180MB of heap growth per emulator
# per run, with the guest's own RAM fixed at 2048MB throughout, which is what ruled out the Android
# side and pointed at the emulator process itself.
#
emulator_heap_bytes() {
    local pid kilobytes

    pid="$(emulator_main_pid "$1")"
    if [ -z "$pid" ] || [ ! -r "/proc/$pid/smaps" ]; then
        return 0
    fi

    kilobytes="$(awk '/\[heap\]$/ { in_heap = 1; next } in_heap && /^Size:/ { print $2; exit }' "/proc/$pid/smaps" 2>/dev/null || true)"
    case "$kilobytes" in
        ''|*[!0-9]*) return 0 ;;
    esac

    echo $(( kilobytes * 1024 ))
}

#
# Prints how many threads one emulator's main process has, or nothing when it cannot be read.
#
emulator_thread_count() {
    local pid

    pid="$(emulator_main_pid "$1")"
    if [ -z "$pid" ] || [ ! -r "/proc/$pid/status" ]; then
        return 0
    fi

    awk '/^Threads:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true
}

#
# Prints how many files one emulator's main process has open, or nothing when it cannot be read.
#
emulator_fd_count() {
    local pid count

    pid="$(emulator_main_pid "$1")"
    if [ -z "$pid" ] || [ ! -d "/proc/$pid/fd" ]; then
        return 0
    fi

    count="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    echo "$count"
}

#
# Prints how many times one emulator has been pushed back over its memory allowance, or nothing when
# it cannot be read.
#
# This is the warning the pool gives before it collapses. `high` counts the times the kernel held the
# emulator back and reclaimed from it because it was over MemoryHigh, and it starts climbing well
# before anything is killed. A session where this stays at zero and one where it is in the thousands
# are measuring different things, and the second is no longer measuring the test.
#
emulator_throttle_events() {
    local cgroup_dir

    cgroup_dir="$(cgroup_dir_for_avd "$1")"
    if [ -z "$cgroup_dir" ] || [ ! -r "$cgroup_dir/memory.events" ]; then
        return 0
    fi

    awk '/^high /{ print $2 }' "$cgroup_dir/memory.events" 2>/dev/null || true
}

#
# Prints the pool's current total across every emulator being watched, in bytes.
#
pool_total_bytes() {
    local avd bytes total=0

    for avd in "${MEASURE_AVDS[@]}"; do
        bytes="$(emulator_memory_bytes "$avd")"
        if [ -n "$bytes" ]; then
            total=$(( total + bytes ))
        fi
    done

    echo "$total"
}

#
# Prints the names of every smoke test, in the order the suite runs them.
#
discover_test_names() {
    find "$TESTS_DIR" -maxdepth 2 -name "test.sh" 2>/dev/null \
        | sort -V \
        | while IFS= read -r test_path; do
            basename "$(dirname "$test_path")"
        done
}

#
# Prints the full directory name of the single test a filter names, or nothing when it matches none.
#
# The rules are the suite's own (see test_matches_filter in apps/smoke-tests/lib/runner.sh): a purely
# numeric filter matches the number at the front of the name, anything else is a case-insensitive
# substring. Resolved here rather than left to the suite so a typo fails in a second, instead of after
# the pool checks and a build.
#
resolve_test_filter() {
    local filter="$1"
    local name number lower_name lower_filter

    lower_filter="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"

    while IFS= read -r name; do
        case "$filter" in
            *[!0-9]*)
                lower_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
                case "$lower_name" in
                    *"$lower_filter"*) echo "$name"; return 0 ;;
                esac
                ;;
            *)
                number="${name%%-*}"
                case "$number" in
                    ""|*[!0-9]*) continue ;;
                esac
                if [ "$((10#$number))" -eq "$((10#$filter))" ]; then
                    echo "$name"
                    return 0
                fi
                ;;
        esac
    done < <(discover_test_names)
}

#
# Refuses to go any further unless the pool is up, and says what to do about it.
#
# Stopping rather than starting the pool is deliberate. Bringing emulators up is the human's job, and
# a session that silently restarted them would reset the very memory it is trying to watch grow.
#
require_running_pool() {
    if [ "$(running_pool_avds | wc -l)" -eq 0 ]; then
        echo -e "${RED}No pool emulators are running, so there is nothing to measure.${NC}" >&2
        echo "" >&2
        echo "Bring the pool up yourself, then run this again:" >&2
        echo "  bun run emu:and:pool:up" >&2
        echo "" >&2
        echo "This script does not start emulators on purpose. Restarting one resets its memory," >&2
        echo "which would erase the growth being measured." >&2
        exit 1
    fi
}

#
# Clears the per-test state so the next test is measured from its own baseline rather than carrying
# the previous test's readings into its averages.
#
start_test() {
    BASELINE_TOTAL=0
    PREVIOUS_TOTAL=0
    COMPLETED_RUNS=0
    FAILED_RUNS=0
    RUN_DELTAS=()
    FIRST_READING=()
    LATEST_READING=()
    DEAD_AVDS=()
    DIED_THIS_RUN=""
    FIRST_HEAP=()
    LATEST_HEAP=()
    FIRST_THREADS=()
    LATEST_THREADS=()
    FIRST_FDS=()
    LATEST_FDS=()
    PREVIOUS_PER_EMULATOR=()
    VERDICT_CLASS=""
    VERDICT_AVERAGE=0
    VERDICT_FIRST_HALF=0
    VERDICT_SECOND_HALF=0
    VERDICT_FIRST_COUNT=0
    VERDICT_SECOND_COUNT=0
}

#
# Prints the average bytes added per run over the runs after warm-up, or 0 when there are none yet.
# Usage: average_growth_per_run <last_run_index>
#
average_growth_per_run() {
    local last_run="$1"
    local counted=0
    local total=0
    local index

    for (( index = WARMUP_RUNS + 1; index <= last_run; index++ )); do
        total=$(( total + RUN_DELTAS[index] ))
        counted=$(( counted + 1 ))
    done

    if [ "$counted" -eq 0 ]; then
        echo 0
        return 0
    fi

    echo $(( total / counted ))
}

#
# Takes a reading from every emulator, appends it to the CSV, and prints its row when <quiet> is not
# "quiet". A sweep measures dozens of tests and wants one line each rather than a table each, but it
# still needs the readings taken and recorded.
#
# Usage: sample_and_report <row_label> <run_index> [quiet]
#
sample_and_report() {
    local label="$1"
    local run_index="$2"
    local quiet="${3:-}"
    local total=0
    local emulator_columns=""
    local avd bytes filled percent delta added_text blocks note average runs_left

    DIED_THIS_RUN=""

    for avd in "${MEASURE_AVDS[@]}"; do
        bytes="$(emulator_memory_bytes "$avd")"
        if [ -z "$bytes" ]; then
            # An emulator that has died leaves its column empty for the rest of the session. Its last
            # reading stays in LATEST_READING so the summary can still say how far it had grown.
            emulator_columns="$emulator_columns,"
            if [ -n "${FIRST_READING[$avd]:-}" ] && [ -z "${DEAD_AVDS[$avd]:-}" ]; then
                DEAD_AVDS["$avd"]="dead"
                DIED_THIS_RUN="$DIED_THIS_RUN $avd"
            fi
            continue
        fi
        total=$(( total + bytes ))
        emulator_columns="$emulator_columns,$bytes"
        if [ -z "${FIRST_READING[$avd]:-}" ]; then
            FIRST_READING["$avd"]="$bytes"
        fi
        LATEST_READING["$avd"]="$bytes"
    done

    echo "$run_index,$total$emulator_columns" >> "$CSV_PATH"

    if [ "$run_index" -eq 0 ]; then
        BASELINE_TOTAL="$total"
        added_text="baseline"
        blocks=""
        note=""
    else
        delta=$(( total - PREVIOUS_TOTAL ))
        RUN_DELTAS[run_index]="$delta"
        added_text="$(format_megabytes_signed "$delta")M"
        blocks="$(render_growth_blocks "$delta")"

        if [ "$run_index" -le "$WARMUP_RUNS" ]; then
            note="warm-up, not counted"
        else
            average="$(average_growth_per_run "$run_index")"
            if [ "$average" -le 0 ]; then
                note="not filling"
            else
                runs_left=$(( (POOL_CEILING - total) / average ))
                note="$runs_left runs left"
            fi
        fi
    fi

    PREVIOUS_TOTAL="$total"

    if [ "$quiet" = "quiet" ]; then
        if [ "$DETAIL" = "true" ]; then
            # The detail readings are still collected during a sweep, which prints no rows, so the
            # closing breakdown has something to report for each test.
            report_detail_rows "$run_index" >/dev/null
        fi
        return 0
    fi

    filled=$(( total * POOL_BAR_WIDTH / POOL_CEILING ))
    percent=$(( total * 100 / POOL_CEILING ))

    # The note is last in the row, so wrapping it in colour cannot throw the columns out: padding is
    # applied to the fields before it, and there is nothing after it to push along.
    printf "$TABLE_FORMAT" \
        "$label" \
        "$(format_gigabytes "$total")G" \
        "$(render_pool_bar "$filled")" \
        "${percent}%" \
        "$added_text" \
        "$blocks" \
        "$(printf "${DIM}%s${NC}" "$note")"

    if [ "$DETAIL" = "true" ]; then
        report_detail_rows "$run_index"
    fi
}

#
# Works out whether the test just measured leaks, and leaves the answer in the VERDICT_* globals.
#
# The test is whether growth is fading, not how much of it there was in total. Memory that grows and
# then stops is a cache filling up and is harmless; memory still being added at the end is what runs
# the pool out. One average over the whole session cannot tell those apart and calls both a leak,
# which is how start-up cost gets mistaken for one. So the runs after warm-up are split down the
# middle and the second half compared against the first: growth that has halved or better is on its
# way out, growth that has held is a leak.
#
classify_verdict() {
    local measured_runs midpoint index
    local first_total=0 second_total=0

    measured_runs=$(( COMPLETED_RUNS - WARMUP_RUNS ))
    if [ "$measured_runs" -lt 2 ]; then
        VERDICT_CLASS="insufficient"
        return 0
    fi

    # midpoint is the first run of the second half. With an odd number of measured runs the spare one
    # falls into the second half, which is the half that decides the verdict and so the one better off
    # with more evidence behind it.
    midpoint=$(( WARMUP_RUNS + 1 + measured_runs / 2 ))

    for (( index = WARMUP_RUNS + 1; index < midpoint; index++ )); do
        first_total=$(( first_total + RUN_DELTAS[index] ))
        VERDICT_FIRST_COUNT=$(( VERDICT_FIRST_COUNT + 1 ))
    done
    for (( index = midpoint; index <= COMPLETED_RUNS; index++ )); do
        second_total=$(( second_total + RUN_DELTAS[index] ))
        VERDICT_SECOND_COUNT=$(( VERDICT_SECOND_COUNT + 1 ))
    done

    if [ "$VERDICT_FIRST_COUNT" -gt 0 ]; then
        VERDICT_FIRST_HALF=$(( first_total / VERDICT_FIRST_COUNT ))
    fi
    if [ "$VERDICT_SECOND_COUNT" -gt 0 ]; then
        VERDICT_SECOND_HALF=$(( second_total / VERDICT_SECOND_COUNT ))
    fi

    VERDICT_AVERAGE="$(average_growth_per_run "$COMPLETED_RUNS")"

    if [ "$VERDICT_AVERAGE" -le "$SETTLED_FLOOR_BYTES" ]; then
        VERDICT_CLASS="none"
    elif [ $(( VERDICT_SECOND_HALF * 2 )) -lt "$VERDICT_FIRST_HALF" ]; then
        VERDICT_CLASS="settling"
    else
        VERDICT_CLASS="leak"
    fi
}

#
# Prints the verdict for a single-test session as a few lines of prose.
#
report_verdict() {
    local runs_to_full

    echo ""
    case "$VERDICT_CLASS" in
        insufficient)
            echo -e "${YELLOW}Not enough runs to say.${NC} Run 1 is warm-up, so at least three runs are needed to"
            echo "compare early runs against late ones."
            return 0
            ;;
        none)
            echo -e "${GREEN}NO LEAK.${NC} The measured runs added $(format_megabytes "$VERDICT_AVERAGE")M each, which is within the noise between"
            echo "two readings of the same idle emulator."
            ;;
        settling)
            echo -e "${YELLOW}NOT A LEAK, STILL SETTLING.${NC} Growth more than halved across the session ($(format_megabytes "$VERDICT_FIRST_HALF")M per run"
            echo "down to $(format_megabytes "$VERDICT_SECOND_HALF")M). That is start-up cost working its way out. Run it again with more"
            echo "runs to confirm it reaches zero and stays there."
            ;;
        leak)
            runs_to_full=$(( (POOL_CEILING - PREVIOUS_TOTAL) / VERDICT_AVERAGE ))
            echo -e "${RED}LEAK.${NC} Growth did not fade: the last $VERDICT_SECOND_COUNT runs added $(format_megabytes "$VERDICT_SECOND_HALF")M each against $(format_megabytes "$VERDICT_FIRST_HALF")M for the"
            echo "first $VERDICT_FIRST_COUNT. At $(format_megabytes "$VERDICT_AVERAGE")M per run the pool has about $runs_to_full runs left before it is full."
            ;;
    esac

    if [ "$FAILED_RUNS" -gt 0 ]; then
        echo ""
        echo "$FAILED_RUNS of the $COMPLETED_RUNS runs failed. See $(format_repo_path "$RUN_LOG_PATH")."
    fi
}

#
# Prints the short label for the current verdict, coloured.
#
verdict_label() {
    case "$VERDICT_CLASS" in
        leak) printf "${RED}LEAK${NC}" ;;
        settling) printf "${YELLOW}settling${NC}" ;;
        none) printf "${GREEN}no leak${NC}" ;;
        *) printf "${DIM}too few runs${NC}" ;;
    esac
}

#
# Prints one indented line per emulator saying what is inside it, under the run's own row.
#
# The per-emulator memory change is here as well as the pool total because the suite spreads tests
# over whichever devices are free. If only the emulator that ran the test grew, the leak follows the
# work; if all of them grew, it is something ambient and the test is not the cause. The pool total
# cannot tell those apart, and they need looking at in completely different places.
#
# Usage: report_detail_rows <run_index>
#
report_detail_rows() {
    local run_index="$1"
    local avd heap threads fds throttled bytes change

    for avd in "${MEASURE_AVDS[@]}"; do
        bytes="${LATEST_READING[$avd]:-}"
        if [ -z "$bytes" ] || [ -n "${DEAD_AVDS[$avd]:-}" ]; then
            printf "         %-18s %s\n" "$avd" "not answering"
            continue
        fi

        heap="$(emulator_heap_bytes "$avd")"
        threads="$(emulator_thread_count "$avd")"
        fds="$(emulator_fd_count "$avd")"
        throttled="$(emulator_throttle_events "$avd")"

        if [ -n "$heap" ]; then
            if [ -z "${FIRST_HEAP[$avd]:-}" ]; then
                FIRST_HEAP["$avd"]="$heap"
            fi
            LATEST_HEAP["$avd"]="$heap"
        fi
        if [ -n "$threads" ]; then
            if [ -z "${FIRST_THREADS[$avd]:-}" ]; then
                FIRST_THREADS["$avd"]="$threads"
            fi
            LATEST_THREADS["$avd"]="$threads"
        fi
        if [ -n "$fds" ]; then
            if [ -z "${FIRST_FDS[$avd]:-}" ]; then
                FIRST_FDS["$avd"]="$fds"
            fi
            LATEST_FDS["$avd"]="$fds"
        fi

        change=""
        if [ "$run_index" -gt 0 ] && [ -n "${PREVIOUS_PER_EMULATOR[$avd]:-}" ]; then
            change="$(format_megabytes_signed $(( bytes - PREVIOUS_PER_EMULATOR[$avd] )))M"
        fi

        printf "         %-18s %6sG  heap %6sG  threads %4s  fds %5s  %8s" \
            "$avd" \
            "$(format_gigabytes "$bytes")" \
            "$(format_gigabytes "${heap:-0}")" \
            "${threads:-?}" \
            "${fds:-?}" \
            "$change"

        if [ -n "$throttled" ] && [ "$throttled" -gt 0 ]; then
            printf "  ${YELLOW}throttled %s times${NC}" "$throttled"
        fi
        printf "\n"
    done

    for avd in "${MEASURE_AVDS[@]}"; do
        PREVIOUS_PER_EMULATOR["$avd"]="${LATEST_READING[$avd]:-}"
    done
}

#
# Prints what grew inside the emulators over the session, so the leak can be named rather than only
# measured.
#
# Memory growing while threads and open files stay flat is memory the emulator allocated and never
# freed, and the heap column says whether it went on the heap or somewhere else. Threads or files
# climbing alongside it is a handle leak, which is a different bug in a different place. That
# distinction is the point of this table.
#
report_detail_summary() {
    local avd measured_runs
    local memory_per_run heap_per_run thread_change fd_change

    measured_runs=$(( COMPLETED_RUNS - WARMUP_RUNS ))
    if [ "$measured_runs" -lt 1 ]; then
        measured_runs=1
    fi

    echo ""
    echo -e "${BOLD}What grew${NC} ${DIM}(per run after warm-up, except threads and files which are totals)${NC}"
    printf "  %-18s %12s %12s %10s %8s\n" "emulator" "memory/run" "heap/run" "threads" "files"

    for avd in "${MEASURE_AVDS[@]}"; do
        if [ -z "${FIRST_READING[$avd]:-}" ] || [ -z "${LATEST_READING[$avd]:-}" ]; then
            printf "  %-18s %s\n" "$avd" "never read"
            continue
        fi

        memory_per_run=$(( (LATEST_READING[$avd] - FIRST_READING[$avd]) / measured_runs ))

        heap_per_run=""
        if [ -n "${FIRST_HEAP[$avd]:-}" ] && [ -n "${LATEST_HEAP[$avd]:-}" ]; then
            heap_per_run="$(format_megabytes_signed $(( (LATEST_HEAP[$avd] - FIRST_HEAP[$avd]) / measured_runs )))M"
        fi

        thread_change=""
        if [ -n "${FIRST_THREADS[$avd]:-}" ] && [ -n "${LATEST_THREADS[$avd]:-}" ]; then
            thread_change="$(( LATEST_THREADS[$avd] - FIRST_THREADS[$avd] ))"
        fi

        fd_change=""
        if [ -n "${FIRST_FDS[$avd]:-}" ] && [ -n "${LATEST_FDS[$avd]:-}" ]; then
            fd_change="$(( LATEST_FDS[$avd] - FIRST_FDS[$avd] ))"
        fi

        printf "  %-18s %11sM %11s %10s %8s\n" \
            "$avd" \
            "$(format_megabytes_signed "$memory_per_run")" \
            "${heap_per_run:-?}" \
            "${thread_change:-?}" \
            "${fd_change:-?}"
    done

    echo ""
    echo -e "${DIM}  Memory climbing while threads and files stay flat means memory allocated and never freed.${NC}"
    echo -e "${DIM}  Threads or files climbing with it means handles never closed, which is a different bug.${NC}"
    echo -e "${DIM}  Heap tracking memory means it is the emulator process itself, not the Android guest.${NC}"
}

#
# Announces that the pool has lost an emulator, which is where the leak ends up.
#
# Printed rather than left for the reader to infer from a total that suddenly fell. It also says what
# to do next, because the answer is not to run this again on what is left: the survivors have been
# through everything the dead one went through, so they are already part way to the same end and a
# fresh measurement on them starts from a false baseline.
#
# Usage: report_pool_collapse <run_index>
#
report_pool_collapse() {
    local run_index="$1"
    local avd survivors

    survivors=$(( ${#MEASURE_AVDS[@]} - ${#DEAD_AVDS[@]} ))

    echo ""
    for avd in $DIED_THIS_RUN; do
        echo -e "${RED}$avd stopped answering during run $run_index. It has been killed or has crashed.${NC}"
    done
    echo -e "${RED}This is the leak reaching its end: an emulator that fills its allowance is throttled${NC}"
    echo -e "${RED}and then killed. $survivors of ${#MEASURE_AVDS[@]} emulators are left.${NC}"
    echo ""
    echo "Stopping here. Readings taken on a pool that has just lost an emulator are not comparable"
    echo "with the ones above, and the surviving emulators are already part way to the same end."
    echo ""
    echo "To measure again from a clean start, restart the pool yourself first:"
    echo "  bun run emu:and:pool:restart"
}

#
# Runs one test RUNS times, taking a reading after each, and classifies the result.
#
# Usage: measure_test <test filter or empty for the whole suite> <quiet|loud>
#
measure_test() {
    local filter="$1"
    local quiet="$2"
    local test_command=()
    local run_index run_status

    if [ -z "$filter" ]; then
        test_command=(bun run test:and)
    else
        test_command=(bun run test:and -- "$filter")
    fi

    start_test
    sample_and_report "start" 0 "$quiet"

    for (( run_index = 1; run_index <= RUNS; run_index++ )); do
        run_status=0

        # The suite's output goes to the log rather than the terminal so the table stays readable, and
        # it is kept rather than thrown away because the runs that fail late in a session are the ones
        # worth reading. A failure does not stop the session: a suite that starts failing because the
        # emulators are full is itself the finding, and stopping would discard the readings that show
        # it happening.
        echo "=== ${filter:-full suite} run $run_index ===" >> "$RUN_LOG_PATH"
        ( cd "$REPO_DIR" && "${test_command[@]}" ) >> "$RUN_LOG_PATH" 2>&1 || run_status=$?

        if [ "$run_status" -ne 0 ]; then
            FAILED_RUNS=$(( FAILED_RUNS + 1 ))
            if [ "$quiet" != "quiet" ]; then
                echo -e "${YELLOW}         run $run_index failed (exit $run_status), carrying on. Output in $(format_repo_path "$RUN_LOG_PATH")${NC}"
            fi
        fi

        sample_and_report "run $run_index" "$run_index" "$quiet"
        COMPLETED_RUNS="$run_index"

        # Stopping the moment an emulator dies, rather than carrying on to the requested run count.
        # This is the end the leak is heading for and it is worth reaching, but nothing measured past
        # it means anything: the pool is a different size, the survivors are absorbing the dead one's
        # share of the work, and the total has just fallen by several gigabytes for a reason that has
        # nothing to do with the test.
        if [ -n "$DIED_THIS_RUN" ]; then
            report_pool_collapse "$run_index"
            break
        fi
    done

    classify_verdict
}

#
# Prints the closing table for a single-test session: where each emulator started and ended.
#
report_per_emulator() {
    local avd start_bytes end_bytes grew per_run measured_runs

    measured_runs=$(( COMPLETED_RUNS - WARMUP_RUNS ))
    if [ "$measured_runs" -lt 1 ]; then
        measured_runs=1
    fi

    echo ""
    echo -e "${BOLD}Each emulator${NC} ${DIM}(growth per run, ignoring warm-up)${NC}"
    for avd in "${MEASURE_AVDS[@]}"; do
        start_bytes="${FIRST_READING[$avd]:-}"
        end_bytes="${LATEST_READING[$avd]:-}"

        if [ -z "$start_bytes" ] || [ -z "$end_bytes" ]; then
            printf "  %-18s %s\n" "$avd" "never read"
            continue
        fi

        grew=$(( end_bytes - start_bytes ))
        per_run=$(( grew / measured_runs ))
        printf "  %-18s %6sG to %6sG   %8sM per run\n" \
            "$avd" \
            "$(format_gigabytes "$start_bytes")" \
            "$(format_gigabytes "$end_bytes")" \
            "$(format_megabytes_signed "$per_run")"
    done
}

#
# Measures every test in turn and prints one line per test, then a worst-first table.
#
# It stops when the pool passes POOL_STOP_PERCENT rather than carrying on to the end. Past that the
# emulators are throttled and reclaiming under pressure, so what a test appears to cost says more
# about the state of the pool than about the test, and a table of those numbers would be worse than
# no table because it looks like an answer. Restarting the pool is the human's to do, so the sweep
# prints the two commands that carry it on and gets out of the way.
#
sweep_all_tests() {
    local names=() name
    local started="false"
    local measured=0
    local percent

    while IFS= read -r name; do
        names+=("$name")
    done < <(discover_test_names)

    echo -e "${BOLD}Sweeping ${#names[@]} tests${NC}, $RUNS runs each (1 warm-up, $(( RUNS - WARMUP_RUNS )) measured)"
    echo -e "${DIM}Stops if the pool passes ${POOL_STOP_PERCENT}% full, because readings taken past that measure the${NC}"
    echo -e "${DIM}state of the pool rather than the test.${NC}"
    echo ""

    for name in "${names[@]}"; do
        if [ -n "$RESUME_FROM" ] && [ "$started" = "false" ]; then
            if [ "$name" = "$RESUME_FROM" ]; then
                started="true"
            else
                continue
            fi
        fi

        percent=$(( $(pool_total_bytes) * 100 / POOL_CEILING ))
        if [ "$percent" -ge "$POOL_STOP_PERCENT" ]; then
            echo ""
            echo -e "${YELLOW}Pool is ${percent}% full. Stopping: anything measured from here would be noise.${NC}"
            echo "$measured of ${#names[@]} tests measured. Restart the pool, then carry on:"
            echo "  bun run emu:and:pool:restart"
            echo "  bun run measure-android-leak -- --all --resume-from $name"
            break
        fi

        printf "  %-32s " "$name"
        measure_test "$name" quiet
        measured=$(( measured + 1 ))

        if [ "$VERDICT_CLASS" = "insufficient" ]; then
            printf "%10s   %b\n" "" "$(verdict_label)"
        else
            printf "%9sM   %b\n" "$(format_megabytes_signed "$VERDICT_AVERAGE")" "$(verdict_label)"
            SWEEP_RESULTS+=("$VERDICT_AVERAGE|$name|$VERDICT_CLASS")
        fi
    done

    if [ "${#SWEEP_RESULTS[@]}" -eq 0 ]; then
        echo ""
        echo "No test produced enough runs to judge."
        return 0
    fi

    echo ""
    echo -e "${BOLD}Worst first${NC} ${DIM}(memory added per run, after warm-up)${NC}"
    local line average test_name verdict_class
    while IFS= read -r line; do
        average="${line%%|*}"
        test_name="${line#*|}"
        verdict_class="${test_name#*|}"
        test_name="${test_name%%|*}"
        VERDICT_CLASS="$verdict_class"
        printf "  %-32s %9sM   %b\n" "$test_name" "$(format_megabytes_signed "$average")" "$(verdict_label)"
    done < <(printf '%s\n' "${SWEEP_RESULTS[@]}" | sort -t'|' -k1 -rn)
}

#
# Reports on the runs that did happen when a session is stopped early, then exits.
#
# Ctrl-C on a long session is normal rather than exceptional: the point of a live table is that it can
# be watched, and someone who has seen enough should not have to throw away the answer to stop. 130 is
# the conventional status for a program stopped by Ctrl-C, so a caller can still tell "stopped by
# hand" from "found nothing".
#
on_interrupt() {
    trap - INT TERM

    echo ""
    echo -e "${YELLOW}Stopped after $COMPLETED_RUNS of $RUNS runs.${NC}"

    if [ "$COMPLETED_RUNS" -gt 0 ]; then
        classify_verdict
        report_per_emulator
        report_verdict
    fi
    echo ""

    exit 130
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --runs)
                RUNS="$2"
                RUNS_GIVEN="true"
                shift 2
                ;;
            --test)
                TEST_FILTER="$2"
                shift 2
                ;;
            --all)
                SWEEP_ALL="true"
                shift
                ;;
            --to-the-end)
                RUN_TO_THE_END="true"
                shift
                ;;
            --detail)
                DETAIL="true"
                shift
                ;;
            --resume-from)
                RESUME_FROM="$2"
                SWEEP_ALL="true"
                shift 2
                ;;
            --full)
                RUN_FULL_SUITE="true"
                shift
                ;;
            --csv)
                CSV_PATH="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Usage: bun run measure-android-leak -- [--test FILTER | --all | --full]" >&2
                echo "                                       [--runs N] [--resume-from TEST] [--csv PATH]" >&2
                exit 1
                ;;
        esac
    done

    if [ "$RUN_TO_THE_END" = "true" ]; then
        if [ "$SWEEP_ALL" = "true" ]; then
            echo "--to-the-end and --all cannot be combined: a sweep needs the pool to survive every" >&2
            echo "test, and running to the end means running until it does not." >&2
            exit 1
        fi
        RUNS="$RUNS_CAP"
    elif [ "$RUNS_GIVEN" = "false" ]; then
        if [ "$SWEEP_ALL" = "true" ]; then
            RUNS="$DEFAULT_RUNS_SWEEP"
        else
            RUNS="$DEFAULT_RUNS_SINGLE"
        fi
    fi

    case "$RUNS" in
        ''|*[!0-9]*)
            echo "--runs needs a whole number, got: $RUNS" >&2
            exit 1
            ;;
    esac
    if [ "$RUNS" -le "$WARMUP_RUNS" ]; then
        echo "--runs needs to be more than $WARMUP_RUNS, since run 1 is warm-up. Got: $RUNS" >&2
        exit 1
    fi

    local resolved_test=""
    if [ "$SWEEP_ALL" = "false" ] && [ "$RUN_FULL_SUITE" = "false" ]; then
        resolved_test="$(resolve_test_filter "$TEST_FILTER")"
        if [ -z "$resolved_test" ]; then
            echo "No test matched: $TEST_FILTER" >&2
            echo "Available tests:" >&2
            discover_test_names | sed 's/^/  /' >&2
            exit 1
        fi
    fi

    if [ -n "$RESUME_FROM" ] && ! discover_test_names | grep -qx -- "$RESUME_FROM"; then
        echo "No such test to resume from: $RESUME_FROM" >&2
        echo "It must be a full test directory name, for example 26-receive-database." >&2
        exit 1
    fi

    require_running_pool

    # The set of emulators is fixed here and not re-read later. A crash part way through has to show
    # up as a column that stops reporting, because that is a result: it is how the leak kills the
    # pool. Re-reading the list would quietly drop the dead emulator and make the total fall, which
    # reads as memory being handed back.
    local avd
    while IFS= read -r avd; do
        MEASURE_AVDS+=("$avd")
    done < <(running_pool_avds)

    PER_EMULATOR_LIMIT="$(emulator_limit_bytes "${MEASURE_AVDS[0]}")"
    POOL_CEILING=$(( PER_EMULATOR_LIMIT * ${#MEASURE_AVDS[@]} ))

    local target run_count_text
    if [ "$SWEEP_ALL" = "true" ]; then
        target="every test"
    elif [ "$RUN_FULL_SUITE" = "true" ]; then
        target="the whole suite"
    else
        target="$resolved_test"
    fi

    if [ "$RUN_TO_THE_END" = "true" ]; then
        run_count_text="until an emulator dies (at most $RUNS runs)"
    else
        run_count_text="$RUNS runs each"
    fi

    echo ""
    echo -e "${BOLD}Android emulator memory leak${NC}"
    echo -e "  ${BLUE}Measuring${NC}  $target, $run_count_text"
    echo -e "  ${BLUE}Emulators${NC}  ${#MEASURE_AVDS[@]}, $(format_gigabytes "$PER_EMULATOR_LIMIT")G each, $(format_gigabytes "$POOL_CEILING")G between them"
    echo -e "  ${BLUE}Counting${NC}   memory the emulators cannot give back (anonymous + swap)"
    echo -e "  ${BLUE}Readings${NC}   $(format_repo_path "$CSV_PATH")"
    echo -e "  ${BLUE}Suite log${NC}  $(format_repo_path "$RUN_LOG_PATH")"
    echo ""

    mkdir -p "$(dirname "$CSV_PATH")"
    mkdir -p "$(dirname "$RUN_LOG_PATH")"
    : > "$RUN_LOG_PATH"

    local csv_header="run,total_bytes"
    for avd in "${MEASURE_AVDS[@]}"; do
        csv_header="$csv_header,$avd"
    done
    echo "$csv_header" > "$CSV_PATH"

    if [ "$SWEEP_ALL" = "true" ]; then
        sweep_all_tests
        echo ""
        return 0
    fi

    echo -e "${DIM}\"added\" is what that run cost: one # per $(format_megabytes "$GROWTH_BLOCK_BYTES")M. Blocks that keep coming mean a leak,${NC}"
    echo -e "${DIM}blocks that fade mean start-up cost. Run 1 is warm-up and is left out of every average.${NC}"
    echo ""

    # Installed only once the table is under way, so an interrupt during start-up dies plainly rather
    # than printing a report about a session that never took a reading.
    trap on_interrupt INT TERM

    printf "$TABLE_FORMAT" "" "pool" "used of $(format_gigabytes "$POOL_CEILING")G" "" "added" "" ""

    if [ "$RUN_FULL_SUITE" = "true" ]; then
        measure_test "" loud
    else
        measure_test "$resolved_test" loud
    fi

    report_per_emulator
    if [ "$DETAIL" = "true" ]; then
        report_detail_summary
    fi
    report_verdict
    echo ""
}

main "$@"
