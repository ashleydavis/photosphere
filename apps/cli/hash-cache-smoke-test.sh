#!/bin/bash

# Photosphere Hash Cache Concurrency Smoke Test
#
# Proves that separate OS processes can write the shared hash cache at the same time without
# losing each other's entries and without corrupting the file. Every write is its own psi process,
# so this exercises the real cross-process path rather than simulating it in one process.
#
# It drives the cache through the hidden "psi hash-cache" commands, and reads the result back
# through them too, so the test and a developer poking at the cache use the same tools.

set -e

# Disable colors for consistent output parsing
export NO_COLOR=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ten parallel processes must not lose a single entry. Beyond that the cache is allowed to start
# dropping writes: it is only an optimization, and a dropped entry costs one recomputed hash.
NUM_PROCESSES=10
ENTRIES_PER_PROCESS=10

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --processes)
            NUM_PROCESSES="$2"
            shift 2
            ;;
        --entries)
            ENTRIES_PER_PROCESS="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--processes N] [--entries N]"
            echo "  --processes N   Number of parallel writer processes (default: 10)"
            echo "  --entries N     Entries each process adds (default: 10)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-run temporary directory, the same allocator every other suite in this repository uses.
source "$SCRIPT_DIR/../../scripts/lib/allocate-test-temp-dir.sh"

# Everything this run writes lives under a directory allocated for this run alone. It used to be a
# fixed path under test/tmp, which broke two ways at once: that tree belongs to smoke-tests.sh, which
# deletes all of it at the start and end of its own run, and a fixed path collides with a second copy
# of this suite from another worktree or an overlapping rerun. Neither showed up while this suite was
# the only thing running.
TEST_ROOT="$(photosphere_test_temp_dir "cli-hash-cache")"
OUTPUT_DIR="$TEST_ROOT/outputs"

# Starting and stopping background processes: the tree walk the trap below stops the writers with.
source "$SCRIPT_DIR/../../scripts/lib/process-control.sh"

# This suite is one script rather than a set of separate tests, so the script itself is what gets
# held to the shared timeout. Without it a wedged run here had no limit at all and kept going until
# something above it gave up, which in CI is the job timeout, and a job killed that way has its log
# discarded rather than written.
source "$SCRIPT_DIR/../../scripts/lib/test-timeout.sh"
start_suite_watchdog "hash-cache-smoke-test"

# Every writer this test backgrounds, so a run that ends early takes them with it.
WRITER_PIDS=()

#
# Stops any writer still running. This test had no trap of any kind, so an assertion failure part
# way through (`set -e` exits immediately) or the parallel runner's SIGTERM left ten writers, and the
# psi process each was driving, running and reparented to init. Each writer is a shell whose psi
# child does the work, so the tree has to be taken rather than the recorded pid alone.
#
stop_writers() {
    local writer_pid
    for writer_pid in "${WRITER_PIDS[@]:-}"; do
        if [ -n "$writer_pid" ]; then
            kill_process_tree "$writer_pid"
        fi
    done
    WRITER_PIDS=()
}
trap stop_writers EXIT
trap 'stop_writers; exit 130' INT
trap 'stop_writers; exit 143' TERM

# Both the writers and the reads resolve the cache directory from TEST_TMP_DIR, so pointing it at
# an isolated directory keeps this test off the developer's real hash cache. PHOTOSPHERE_TMP_DIR goes
# with it so the CLI's own scratch files land there too rather than in the shared /tmp/photosphere.
photosphere_export_test_temp "$TEST_ROOT"

# The database whose cache this test drives. There is one hash cache per database, so every
# hash-cache command names one. Nothing here creates a database: the cache directory is derived from
# the path, and these hidden commands act on the cache alone.
TEST_DB="$TEST_ROOT/db"

EXPECTED_ENTRIES=$((NUM_PROCESSES * ENTRIES_PER_PROCESS))

# Runs a psi command quietly, so its output can be parsed. --quiet suppresses the update and news
# notifications the CLI prints before a command runs: on a machine that has never run psi they land
# in the middle of the output this test reads, and the contention check below counts them as a
# writer complaining. It goes before the command name because it is a top-level option.
psi_cmd() {
    (cd "$SCRIPT_DIR" && bun run --silent start -- --quiet "$@")
}

echo -e "${BLUE}=== Hash Cache Concurrency Smoke Test ===${NC}"
echo "Writer processes:    $NUM_PROCESSES"
echo "Entries per process: $ENTRIES_PER_PROCESS"
echo "Expected entries:    $EXPECTED_ENTRIES"
echo ""

# No delete first: the directory above was allocated for this run and is already empty. Deleting it
# would take the one mktemp just handed out, and nothing else has ever written there.
mkdir -p "$OUTPUT_DIR"

# Each writer adds its own entries, one psi process per entry, so the processes are constantly
# loading and saving the same cache file at the same time.
run_writer() {
    local writerName="$1"

    for ((entryIndex = 0; entryIndex < ENTRIES_PER_PROCESS; entryIndex++)); do
        local entryPath="$writerName/file-$entryIndex.dat"
        local entryHash
        entryHash=$(printf '%s' "$entryPath" | sha256sum | cut -d' ' -f1)
        psi_cmd hash-cache set --db "$TEST_DB" "$entryPath" "$entryHash" "$entryIndex"
    done

    echo "$writerName: added $ENTRIES_PER_PROCESS entries"
}

echo -e "${YELLOW}Starting $NUM_PROCESSES writer processes...${NC}"

PIDS=()
for ((processIndex = 1; processIndex <= NUM_PROCESSES; processIndex++)); do
    WRITER_NAME="writer$processIndex"
    run_writer "$WRITER_NAME" > "$OUTPUT_DIR/$WRITER_NAME.log" 2>&1 &
    PIDS+=($!)
    WRITER_PIDS+=($!)
done

FAILED_PROCESSES=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAILED_PROCESSES=$((FAILED_PROCESSES + 1))
    fi
done
# Every writer has been waited on, so there is nothing left for the exit trap to stop.
WRITER_PIDS=()

echo ""
if [ "$FAILED_PROCESSES" -gt 0 ]; then
    echo -e "${RED}FAIL: $FAILED_PROCESSES writer process(es) exited with an error${NC}"
    for logFile in "$OUTPUT_DIR"/*.log; do
        echo "--- $logFile ---"
        cat "$logFile"
    done
    exit 1
fi
echo -e "${GREEN}All $NUM_PROCESSES writer processes completed without error${NC}"

# Contention must be silent. Nothing beyond each writer's own summary line may be printed, because
# a user running an import should never see the cache complaining about load.
UNEXPECTED_OUTPUT=$(cat "$OUTPUT_DIR"/*.log | grep -v "added $ENTRIES_PER_PROCESS entries" || true)
if [ -n "$UNEXPECTED_OUTPUT" ]; then
    echo -e "${RED}FAIL: the writers printed warnings or errors under contention:${NC}"
    echo "$UNEXPECTED_OUTPUT"
    exit 1
fi
echo -e "${GREEN}No warnings or errors were printed under contention${NC}"

echo ""
echo -e "${YELLOW}Reading the cache back...${NC}"

ACTUAL_ENTRIES=$(psi_cmd hash-cache count --db "$TEST_DB")
echo "Cache holds $ACTUAL_ENTRIES entries"

# Every entry every process added must be present, with the hash it was stored with.
CACHED_PATHS="$OUTPUT_DIR/cached-paths.txt"
psi_cmd hash-cache list --db "$TEST_DB" > "$CACHED_PATHS"

MISSING=0
for ((processIndex = 1; processIndex <= NUM_PROCESSES; processIndex++)); do
    for ((entryIndex = 0; entryIndex < ENTRIES_PER_PROCESS; entryIndex++)); do
        if ! grep -qx "writer$processIndex/file-$entryIndex.dat" "$CACHED_PATHS"; then
            echo -e "${RED}  missing: writer$processIndex/file-$entryIndex.dat${NC}"
            MISSING=$((MISSING + 1))
        fi
    done
done

if [ "$MISSING" -gt 0 ] || [ "$ACTUAL_ENTRIES" != "$EXPECTED_ENTRIES" ]; then
    echo -e "${RED}FAIL: expected $EXPECTED_ENTRIES entries, the cache holds $ACTUAL_ENTRIES ($MISSING missing)${NC}"
    exit 1
fi

# Spot check that an entry survived with its own hash, not another writer's.
SPOT_PATH="writer1/file-0.dat"
SPOT_EXPECTED=$(printf '%s' "$SPOT_PATH" | sha256sum | cut -d' ' -f1)
SPOT_ACTUAL=$(psi_cmd hash-cache get --db "$TEST_DB" "$SPOT_PATH")
if [ "$SPOT_ACTUAL" != "$SPOT_EXPECTED" ]; then
    echo -e "${RED}FAIL: $SPOT_PATH has hash $SPOT_ACTUAL, expected $SPOT_EXPECTED${NC}"
    exit 1
fi
echo -e "${GREEN}Entry contents survived intact${NC}"

# Removing an entry must stick, and must not disturb the rest.
psi_cmd hash-cache remove --db "$TEST_DB" "$SPOT_PATH"
if psi_cmd hash-cache get --db "$TEST_DB" "$SPOT_PATH" > /dev/null 2>&1; then
    echo -e "${RED}FAIL: $SPOT_PATH is still cached after being removed${NC}"
    exit 1
fi

AFTER_REMOVE=$(psi_cmd hash-cache count --db "$TEST_DB")
if [ "$AFTER_REMOVE" != "$((EXPECTED_ENTRIES - 1))" ]; then
    echo -e "${RED}FAIL: after removing one entry the cache holds $AFTER_REMOVE, expected $((EXPECTED_ENTRIES - 1))${NC}"
    exit 1
fi
echo -e "${GREEN}Removal applied cleanly${NC}"

echo ""
echo -e "${GREEN}PASS: all $EXPECTED_ENTRIES entries from $NUM_PROCESSES parallel processes survived${NC}"
