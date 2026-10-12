#!/usr/bin/env bash

# Runs Photosphere's smoke test scenarios for one platform. Invoked by the root package.json scripts, never directly. See run.md.

set -u

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/test-lib.sh"
source "$REPO_ROOT/scripts/lib/test-timeout.sh"
source "$REPO_ROOT/scripts/lib/process-control.sh"
source "$REPO_ROOT/scripts/lib/test-pool.sh"
source "$REPO_ROOT/scripts/lib/test-concurrency.sh"

PLATFORM="${1:-}"
SCENARIO_FILTER="${2:-${PHOTOSPHERE_SMOKE_SCENARIO:-}}"

case "$PLATFORM" in
    linux|windows|macos|android|ios)
        ;;
    *)
        echo "Usage: run.sh <linux|windows|macos|android|ios> [scenario number or name]" >&2
        exit 2
        ;;
esac

if [ ! -f "$SMOKE_DIR/lib/$PLATFORM.sh" ]; then
    echo "There is no platform library for $PLATFORM: $SMOKE_DIR/lib/$PLATFORM.sh" >&2
    exit 2
fi

# Every process this run starts is recorded as it is launched, so it can be checked for leaks and cleaned up at the end.
export PHOTOSPHERE_LAUNCHED_GROUPS
PHOTOSPHERE_LAUNCHED_GROUPS="$(mktemp "${TMPDIR:-/tmp}/photosphere-app-launched-XXXXXX")"

RUN_DIR="$(photosphere_test_temp_dir "photosphere-app-run")"
export PHOTOSPHERE_SMOKE_RUN_DIR="$RUN_DIR"
export PHOTOSPHERE_SMOKE_DIR="$SMOKE_DIR"
export PHOTOSPHERE_SMOKE_PLATFORM="$PLATFORM"
export PHOTOSPHERE_SMOKE_REPO_ROOT="$REPO_ROOT"

cleanup_run() {
    local kind pgid
    while read -r kind pgid; do
        if [ "$kind" = "pgid" ]; then
            kill_process_group "$pgid" || true
        fi
    done < "$PHOTOSPHERE_LAUNCHED_GROUPS"
    rm -f "$PHOTOSPHERE_LAUNCHED_GROUPS"
}
trap cleanup_run EXIT

source "$SMOKE_DIR/lib/$PLATFORM.sh"

echo "Building Photosphere for $PLATFORM..."
if ! photosphere_platform_prepare "$RUN_DIR"; then
    echo "FAILED: could not build Photosphere for $PLATFORM." >&2
    exit 1
fi

#
# Prints the scenario directories this platform runs, one per line, in numeric order. A scenario that cannot run on a platform exits
# with the skipped code itself.
#
list_scenarios() {
    {
        ls -d "$SMOKE_DIR"/[0-9]*
        # Manual scenarios measure a real device and are never part of an unfiltered run. They run only when named.
        if [ -n "$SCENARIO_FILTER" ]; then
            ls -d "$SMOKE_DIR"/manual/[0-9]* 2>/dev/null
        fi
    } | while IFS= read -r directory; do
        printf '%s\t%s\n' "$(basename "$directory")" "$directory"
    done | sort -V | cut -f2
}

passed=0
failed=0
skipped=0
failed_names=""

#
# Starts one scenario in the background under the per-scenario timeout, with all its output going to a log of its own so scenarios
# running beside each other do not interleave. Leaves the job's pid and what report_scenario needs in the test pool's globals.
# Usage: start_scenario <scenario test.sh path>
#
start_scenario() {
    local scenario_dir scenario_name test_dir
    scenario_dir="$(dirname "$1")"
    scenario_name="$(basename "$scenario_dir")"
    test_dir="$(photosphere_test_temp_dir "photosphere-app-$scenario_name")"
    PHOTOSPHERE_TMP_DIR="$test_dir" run_test_with_timeout "$PHOTOSPHERE_PER_TEST_TIMEOUT" bash "$1" < /dev/null > "$test_dir/scenario-run.log" 2>&1 &
    TEST_POOL_JOB_PID=$!
    TEST_POOL_JOB_CONTEXT="$test_dir"
}

#
# Prints a finished scenario's output together, then its verdict, and counts it.
# Usage: report_scenario <status> <scenario test.sh path> <test dir>
#
report_scenario() {
    local status="$1"
    local scenario_name test_dir="$3"
    scenario_name="$(basename "$(dirname "$2")")"
    echo "--- $scenario_name"
    cat "$test_dir/scenario-run.log"
    if [ "$status" -eq 0 ]; then
        echo "PASSED: $scenario_name"
        passed=$((passed + 1))
    elif [ "$status" -eq 77 ]; then
        echo "SKIPPED: $scenario_name"
        skipped=$((skipped + 1))
    else
        if test_timed_out "$status"; then
            echo "FAILED: $scenario_name ran out of time. Its files are in $test_dir"
        else
            echo "FAILED: $scenario_name (exit $status). Its files are in $test_dir"
        fi
        failed=$((failed + 1))
        failed_names="$failed_names $scenario_name"
    fi
}

scenarios=()
while IFS= read -r scenario_dir; do
    [ -f "$scenario_dir/test.sh" ] || continue
    scenario_name="$(basename "$scenario_dir")"
    scenario_number="${scenario_name%%-*}"
    if [ -n "$SCENARIO_FILTER" ] && [ "$SCENARIO_FILTER" != "$scenario_name" ] && [ "$SCENARIO_FILTER" != "$scenario_number" ]; then
        continue
    fi
    scenarios+=("$scenario_dir/test.sh")
done < <(list_scenarios)

# As wide as the machine allows on every platform, the same way the other suites decide it. A platform whose scenarios each need a
# device of their own also says how many it has, and the pool is never wider than that. Never more than there are scenarios.
pool_width="$(resolve_test_parallel 2)" || exit 1
if declare -F photosphere_platform_device_limit > /dev/null; then
    device_limit="$(photosphere_platform_device_limit)"
    if [ "$device_limit" -lt "$pool_width" ]; then
        pool_width="$device_limit"
    fi
fi
if [ "$pool_width" -gt "${#scenarios[@]}" ] && [ "${#scenarios[@]}" -gt 0 ]; then
    pool_width="${#scenarios[@]}"
fi
echo "Running ${#scenarios[@]} scenario(s), up to $pool_width at once."
if [ "${#scenarios[@]}" -gt 0 ]; then
    run_test_pool "$pool_width" start_scenario report_scenario "${scenarios[@]}"
fi

leaked="$(list_leaked_launches)"
if [ -n "$leaked" ]; then
    echo "FAILED: processes this run started are still running:" >&2
    echo "$leaked" >&2
    failed=$((failed + 1))
fi

echo "Passed $passed, skipped $skipped, failed $failed."
if [ "$failed" -ne 0 ]; then
    echo "Failed:$failed_names"
    exit 1
fi
if [ "$passed" -eq 0 ]; then
    echo "No scenario ran." >&2
    exit 1
fi
exit 0
