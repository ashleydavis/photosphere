#!/bin/bash
DESCRIPTION="Parallel Zig CLI processes write one hash cache without losing an entry"

# Proves that separate OS processes can write the shared hash cache at the same time without losing
# each other's entries and without corrupting the file. Every write is its own psi process, so this
# exercises the real cross-process path rather than simulating it in one process.
#
# It drives the cache through the hidden "psi hash-cache" commands, and reads the result back through
# them too, so the test and a developer poking at the cache use the same tools. Every psi command runs
# in the Zig CLI.

# The runner exports NODE_ENV=testing, which the standalone script this test was ported from never
# set, so the CLIs here run without it as they did there. For the same reason this test runs its
# commands directly rather than through lib/common.sh's command runner or its verify_database, both
# of which put NODE_ENV=testing back in front of the command.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Starting and stopping background processes: the tree walk the exit trap stops the writers with.
source "$REPO_ROOT/scripts/lib/process-control.sh"

# Ten parallel processes must not lose a single entry. Beyond that the cache is allowed to start
# dropping writes: it is only an optimization, and a dropped entry costs one recomputed hash.
NUM_PROCESSES=10
ENTRIES_PER_PROCESS=10

OUTPUT_DIR="$TEST_TMP_DIR/outputs"

# Every writer this test backgrounds, so a run that ends early takes them with it.
WRITER_PIDS=()

#
# Stops any writer still running, keeping the exit code it was entered with so the summary that runs
# after it reports the test's own result. Each writer is a shell whose psi child does the work, so the
# tree has to be taken rather than the recorded pid alone.
#
stop_writers() {
    local exit_code=$?
    local writer_pid
    for writer_pid in "${WRITER_PIDS[@]:-}"; do
        if [ -n "$writer_pid" ]; then
            kill_process_tree "$writer_pid"
        fi
    done
    WRITER_PIDS=()
    return $exit_code
}
trap 'stop_writers; cleanup_and_show_summary' EXIT
trap 'stop_writers; exit 130' INT
trap 'stop_writers; exit 143' TERM

# The database whose cache this test drives. There is one hash cache per database, so every
# hash-cache command names one. Nothing here creates a database: the cache directory is derived from
# the path, and these hidden commands act on the cache alone.
TEST_DB="$TEST_TMP_DIR/db"

EXPECTED_ENTRIES=$((NUM_PROCESSES * ENTRIES_PER_PROCESS))

ZIG_CLI="$(get_zig_cli_command)"

#
# Runs a psi command in the Zig CLI quietly, so its output can be parsed. --quiet suppresses the
# update and news notifications the CLI prints before a command runs: on a machine that has never run
# psi they land in the middle of the output this test reads, and the contention check below counts
# them as a writer complaining. It goes before the command name because it is a top-level option.
#
psi_cmd() {
    "$ZIG_CLI" --quiet "$@"
}

#
# Prints the SHA-256 of standard input as hex, with whichever tool the platform has: macOS has
# shasum but no sha256sum.
#
sha256_of_stdin() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

#
# Each writer adds its own entries, one psi process per entry, so the processes are constantly
# loading and saving the same cache file at the same time. A failed write ends the writer with a
# non-zero exit code, which the wait below counts.
#
run_writer() {
    local writerName="$1"

    for ((entryIndex = 0; entryIndex < ENTRIES_PER_PROCESS; entryIndex++)); do
        local entryPath="$writerName/file-$entryIndex.dat"
        local entryHash
        entryHash=$(printf '%s' "$entryPath" | sha256_of_stdin)
        psi_cmd hash-cache set --db "$TEST_DB" "$entryPath" "$entryHash" "$entryIndex" || return 1
    done

    echo "$writerName: added $ENTRIES_PER_PROCESS entries"
}

echo -e "${BLUE}=== Hash Cache Concurrency Smoke Test (Zig) ===${NC}"
echo "Writer processes:    $NUM_PROCESSES"
echo "Entries per process: $ENTRIES_PER_PROCESS"
echo "Expected entries:    $EXPECTED_ENTRIES"
echo ""

mkdir -p "$OUTPUT_DIR"

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
    for logFile in "$OUTPUT_DIR"/*.log; do
        echo "--- $logFile ---"
        cat "$logFile"
    done
    test_failed "FAIL: $FAILED_PROCESSES writer process(es) exited with an error"
fi
echo -e "${GREEN}All $NUM_PROCESSES writer processes completed without error${NC}"

# Contention must be silent. Nothing beyond each writer's own summary line may be printed, because
# a user running an import should never see the cache complaining about load.
UNEXPECTED_OUTPUT=$(cat "$OUTPUT_DIR"/*.log | grep -v "added $ENTRIES_PER_PROCESS entries" || true)
if [ -n "$UNEXPECTED_OUTPUT" ]; then
    echo "$UNEXPECTED_OUTPUT"
    test_failed "FAIL: the writers printed warnings or errors under contention"
fi
echo -e "${GREEN}No warnings or errors were printed under contention${NC}"

echo ""
echo -e "${YELLOW}Reading the cache back...${NC}"

# The standalone script ran under set -e, so a psi command that failed ended the run. This test does
# not use set -e (test_passed's counter increment returns non-zero), so each of those commands fails
# the test itself.
ACTUAL_ENTRIES=$(psi_cmd hash-cache count --db "$TEST_DB") || test_failed "FAIL: the Zig CLI could not count the cache entries"
echo "Cache holds $ACTUAL_ENTRIES entries"

# Every entry every process added must be present, with the hash it was stored with.
CACHED_PATHS="$OUTPUT_DIR/cached-paths.txt"
psi_cmd hash-cache list --db "$TEST_DB" > "$CACHED_PATHS" || test_failed "FAIL: the Zig CLI could not list the cache entries"

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
    test_failed "FAIL: expected $EXPECTED_ENTRIES entries, the cache holds $ACTUAL_ENTRIES ($MISSING missing)"
fi

# Spot check that an entry survived with its own hash, not another writer's.
SPOT_PATH="writer1/file-0.dat"
SPOT_EXPECTED=$(printf '%s' "$SPOT_PATH" | sha256_of_stdin)
SPOT_ACTUAL=$(psi_cmd hash-cache get --db "$TEST_DB" "$SPOT_PATH") || test_failed "FAIL: the Zig CLI could not get $SPOT_PATH"
if [ "$SPOT_ACTUAL" != "$SPOT_EXPECTED" ]; then
    test_failed "FAIL: $SPOT_PATH has hash $SPOT_ACTUAL, expected $SPOT_EXPECTED"
fi
echo -e "${GREEN}Entry contents survived intact${NC}"

# Removing an entry must stick, and must not disturb the rest.
psi_cmd hash-cache remove --db "$TEST_DB" "$SPOT_PATH" || test_failed "FAIL: the Zig CLI could not remove $SPOT_PATH"
if psi_cmd hash-cache get --db "$TEST_DB" "$SPOT_PATH" > /dev/null 2>&1; then
    test_failed "FAIL: $SPOT_PATH is still cached after being removed"
fi

AFTER_REMOVE=$(psi_cmd hash-cache count --db "$TEST_DB") || test_failed "FAIL: the Zig CLI could not count the cache entries after the removal"
if [ "$AFTER_REMOVE" != "$((EXPECTED_ENTRIES - 1))" ]; then
    test_failed "FAIL: after removing one entry the cache holds $AFTER_REMOVE, expected $((EXPECTED_ENTRIES - 1))"
fi
echo -e "${GREEN}Removal applied cleanly${NC}"

# An entry the removal did not name must still be there, with its hash.
OTHER_SPOT_PATH="writer2/file-1.dat"
OTHER_SPOT_EXPECTED=$(printf '%s' "$OTHER_SPOT_PATH" | sha256_of_stdin)
OTHER_SPOT_ACTUAL=$(psi_cmd hash-cache get --db "$TEST_DB" "$OTHER_SPOT_PATH") || test_failed "FAIL: the Zig CLI could not get $OTHER_SPOT_PATH after the removal"
if [ "$OTHER_SPOT_ACTUAL" != "$OTHER_SPOT_EXPECTED" ]; then
    test_failed "FAIL: after the removal $OTHER_SPOT_PATH reads as $OTHER_SPOT_ACTUAL, expected $OTHER_SPOT_EXPECTED"
fi
echo -e "${GREEN}The other entries are untouched by the removal${NC}"

echo ""
echo -e "${GREEN}PASS: all $EXPECTED_ENTRIES entries from $NUM_PROCESSES parallel processes survived${NC}"
test_passed
