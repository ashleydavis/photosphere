#!/usr/bin/env bash
#
# Runs a test command repeatedly to surface flaky failures, bombing out at the first failing run.
# Used by the /check-flaky-tests command so the loop is fixed and identical every time rather than
# improvised. The command to run is passed as arguments and can be anything (a `bun run` target, a
# shell script, pytest, etc.); it is executed through `mise exec` so the repo's pinned tool versions
# are used.
#
# Each run is timed and its pass/fail result recorded, and a per-run summary is printed at the end.
# All console output (stdout and stderr) of every run is captured to a log file under the repo's
# gitignored .flaky-check/ dir (never the system temp dir). On a failure, any
# suite-side log files that do not go through stdout (for example the mobile smoke suite's per-test
# app.log/bridge.log) are also snapshotted, so the failure can be reviewed in full even after the
# suite is next run and wipes its own tmp dirs. The console log path is printed on the last line as
# `LOG=<path>`, and any snapshot dir as `SUITE_LOGS=<path>`, so the caller can read them.
#
# Usage:
#   scripts/check-flaky-tests.sh --list        print the repo's test/smoke suite targets, one per line
#   scripts/check-flaky-tests.sh <command...>   run <command> repeatedly, e.g. `bun run test:and`
#
# Environment:
#   RUNS  how many times to run before declaring it non-flaky (default 10)
#
# Exit status: 0 if every run passed (or for --list), 1 if a run failed, 2 on bad usage.
#
set -uo pipefail

# Repo root, resolved from this script's location so it works from any working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --list prints the repo's test/smoke suite targets from the root package.json, one per line, so the
# /check-flaky-tests menu is built from the live scripts instead of a hardcoded (stale-prone) list.
# Watch-mode targets are excluded because they never terminate and are not suites to flaky-check.
if [ "${1:-}" = "--list" ]; then
    node -e "const s=require('$ROOT/package.json').scripts||{}; for (const k of Object.keys(s)) if (/(^|:)(test|smoke)/.test(k) && !/watch/.test(k)) console.log(k)"
    exit 0
fi

# Number of runs before the command is declared non-flaky.
RUNS="${RUNS:-10}"

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/check-flaky-tests.sh <command...>   (e.g. bun run test:and)" >&2
    echo "       scripts/check-flaky-tests.sh --list         (list the repo's test suites)" >&2
    exit 2
fi

# Durable output dir for this check, holding the console log and any failure snapshot. Kept inside
# the repo under .flaky-check/ (gitignored) rather than /tmp, so captures persist with the repo and
# nothing is written to the system temp dir.
CAPTURE_ROOT="$ROOT/.flaky-check"
mkdir -p "$CAPTURE_ROOT"
OUTDIR="$(mktemp -d "$CAPTURE_ROOT/run-XXXXXX")"
LOG="$OUTDIR/console.log"
echo "Logging to $LOG"
echo "Command: $*" | tee -a "$LOG"

# Tracks whether any run failed so we can exit non-zero after breaking the loop.
status=0

# One summary line per run: "Run N: PASS (Ds)" or "Run N: FAIL (Ds)".
SUMMARY_LINES=()

overall_start="$(date +%s)"

for i in $(seq 1 "$RUNS"); do
    echo "===== RUN $i of $RUNS =====" | tee -a "$LOG"
    run_start="$(date +%s)"
    if mise exec -- bash -c "$*" 2>&1 | tee -a "$LOG"; then
        run_duration="$(( $(date +%s) - run_start ))"
        echo "===== RUN $i passed (${run_duration}s) =====" | tee -a "$LOG"
        SUMMARY_LINES+=("Run $i: PASS (${run_duration}s)")
    else
        run_duration="$(( $(date +%s) - run_start ))"
        echo "===== RUN $i FAILED (${run_duration}s) =====" | tee -a "$LOG"
        SUMMARY_LINES+=("Run $i: FAIL (${run_duration}s)")
        status=1
        break
    fi
done

total_duration="$(( $(date +%s) - overall_start ))"

if [ "$status" -ne 0 ]; then
    # Snapshot suite-side log files (those that do not reach stdout) so they survive the next run's
    # tmp wipe. Only known suite log locations are collected; suites that log to stdout are already
    # fully captured above.
    SUITE_LOGS="$OUTDIR/suite-logs"
    found=0
    while IFS= read -r logfile; do
        rel="${logfile#"$ROOT"/}"
        dest="$SUITE_LOGS/$(dirname "$rel")"
        mkdir -p "$dest"
        cp "$logfile" "$dest/"
        found=1
    done < <(find "$ROOT/apps/smoke-tests/tests" -path '*/tmp/*.log' -type f 2>/dev/null)
    if [ "$found" -eq 1 ]; then
        echo "SUITE_LOGS=$SUITE_LOGS" | tee -a "$LOG"
    fi
fi

# Per-run timing and result summary.
{
    echo "===== SUMMARY ====="
    echo "Command: $*"
    if [ "${#SUMMARY_LINES[@]}" -gt 0 ]; then
        for summary_line in "${SUMMARY_LINES[@]}"; do
            echo "$summary_line"
        done
    fi
    if [ "$status" -eq 0 ]; then
        echo "Result: PASSED (${RUNS}/${RUNS} runs)"
    else
        echo "Result: FAILED on run ${#SUMMARY_LINES[@]} of ${RUNS}"
    fi
    echo "Total: ${total_duration}s"
} | tee -a "$LOG"

# Printed last so the caller can grep the log path from stdout.
echo "LOG=$LOG"
exit "$status"
