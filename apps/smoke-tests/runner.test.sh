#!/usr/bin/env bash
# Tests lib/runner.sh: the work queue, the scheduling markers, and the worker pool's exclusivity.
# Everything here runs against stub test scripts in a temp directory: no device, no emulator, and no
# real smoke test is involved, so this is safe to run anywhere.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# runner.sh expects the colour variables common.sh defines. Defined here rather than sourcing
# common.sh, which would load a platform launcher and demand a device.
RED=''
GREEN=''
BLUE=''
NC=''

source "$HERE/lib/runner.sh"

WORK="$(mktemp -d)"
fails=0
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$2', got '$3')"
        fails=$((fails + 1))
    fi
}

#
# Creates a stub test at <dir>/test.sh that exits with the given status, optionally sleeping first,
# and prints the path. Any extra arguments are marker file names to create alongside it.
# Usage: make_stub <name> <exit_status> <sleep_seconds> [marker...]
#
make_stub() {
    local name="$1"
    local exit_status="$2"
    local sleep_seconds="$3"
    shift 3
    local dir="$WORK/tests/$name"
    mkdir -p "$dir"
    {
        echo '#!/bin/bash'
        echo "sleep $sleep_seconds"
        echo "exit $exit_status"
    } > "$dir/test.sh"
    local marker
    for marker in "$@"; do
        touch "$dir/$marker"
    done
    echo "$dir/test.sh"
}

#
# Creates a stub that records concurrent execution: it bumps a counter under a lock on entry, notes
# the high-water mark, sleeps, then decrements. Lets a test prove whether two stubs ever overlapped.
# Usage: make_concurrency_stub <name> <counter_dir> [marker...]
#
make_concurrency_stub() {
    local name="$1"
    local counter_dir="$2"
    shift 2
    local dir="$WORK/tests/$name"
    mkdir -p "$dir"
    cat > "$dir/test.sh" <<STUB
#!/bin/bash
COUNTER_DIR="$counter_dir"
exec 5<>"\$COUNTER_DIR/lock"
flock 5
current=\$(( \$(cat "\$COUNTER_DIR/current") + 1 ))
echo "\$current" > "\$COUNTER_DIR/current"
if [ "\$current" -gt "\$(cat "\$COUNTER_DIR/max")" ]; then
    echo "\$current" > "\$COUNTER_DIR/max"
fi
flock -u 5
sleep 0.6
flock 5
echo \$(( \$(cat "\$COUNTER_DIR/current") - 1 )) > "\$COUNTER_DIR/current"
flock -u 5
exit 0
STUB
    local marker
    for marker in "$@"; do
        touch "$dir/$marker"
    done
    echo "$dir/test.sh"
}

#
# Creates a fresh concurrency counter directory and prints its path.
#
make_counter_dir() {
    local dir="$WORK/counter-$1"
    mkdir -p "$dir"
    echo 0 > "$dir/current"
    echo 0 > "$dir/max"
    : > "$dir/lock"
    echo "$dir"
}

echo "== queue_init =="

QUEUE="$WORK/queue"
queue_init "$QUEUE" a b c
check "queue_init writes one entry per line" "3" "$(wc -l < "$QUEUE")"
check "queue_init preserves order" "a b c" "$(tr '\n' ' ' < "$QUEUE" | sed 's/ $//')"

queue_init "$QUEUE" x
check "queue_init replaces any previous contents" "x" "$(cat "$QUEUE")"

echo "== queue_pop =="

queue_init "$QUEUE" first second third
check "queue_pop returns the first entry" "first" "$(queue_pop "$QUEUE")"
check "queue_pop returns the next entry" "second" "$(queue_pop "$QUEUE")"
check "queue_pop returns the last entry" "third" "$(queue_pop "$QUEUE")"
check "queue_pop prints nothing when the queue is empty" "" "$(queue_pop "$QUEUE")"
check "queue_pop exits 0 when the queue is empty" "0" "$?"
check "queue_pop prints nothing when the queue file is missing" "" "$(queue_pop "$WORK/no-such-queue")"
check "queue_pop exits 0 when the queue file is missing" "0" "$?"

echo "== queue_pop under concurrency =="

# The mutual-exclusion proof: several poppers draining one queue must consume every entry exactly
# once between them, losing none and duplicating none.
CONCURRENT_QUEUE="$WORK/concurrent-queue"
ENTRIES=()
for index in $(seq 1 60); do
    ENTRIES+=("entry-$index")
done
queue_init "$CONCURRENT_QUEUE" "${ENTRIES[@]}"

POPPED_DIR="$WORK/popped"
mkdir -p "$POPPED_DIR"
for popper in 1 2 3 4 5 6; do
    (
        while true; do
            item="$(queue_pop "$CONCURRENT_QUEUE")"
            if [ -z "$item" ]; then
                break
            fi
            echo "$item" >> "$POPPED_DIR/popper-$popper"
        done
    ) &
done
wait

TOTAL_POPPED="$(cat "$POPPED_DIR"/popper-* 2>/dev/null | wc -l)"
UNIQUE_POPPED="$(cat "$POPPED_DIR"/popper-* 2>/dev/null | sort -u | wc -l)"
check "every queue entry was popped exactly once (total)" "60" "$TOTAL_POPPED"
check "every queue entry was popped exactly once (unique)" "60" "$UNIQUE_POPPED"

echo "== test_has_marker =="

MARKED="$(make_stub marked 0 0 .exclusive)"
UNMARKED="$(make_stub unmarked 0 0)"
test_has_marker "$MARKED" ".exclusive"
check "test_has_marker is true for a directory with the marker" "0" "$?"
test_has_marker "$UNMARKED" ".exclusive"
check "test_has_marker is false for a directory without the marker" "1" "$?"
test_has_marker "$WORK/tests/absent/test.sh" ".exclusive"
check "test_has_marker is false for a missing directory" "1" "$?"

echo "== order_tests =="

PLAIN_ONE="$(make_stub plain-one 0 0)"
SLOW_ONE="$(make_stub slow-one 0 0 .slow)"
PLAIN_TWO="$(make_stub plain-two 0 0)"

ORDERED="$(order_tests "$PLAIN_ONE" "$SLOW_ONE" "$PLAIN_TWO")"
check "order_tests puts the slow test first" "$SLOW_ONE" "$(echo "$ORDERED" | head -1)"
check "order_tests preserves the order of the rest" "$PLAIN_ONE $PLAIN_TWO" "$(echo "$ORDERED" | tail -n +2 | tr '\n' ' ' | sed 's/ $//')"

UNMARKED_ORDER="$(order_tests "$PLAIN_ONE" "$PLAIN_TWO")"
check "order_tests leaves a list with no markers unchanged" "$PLAIN_ONE $PLAIN_TWO" "$(echo "$UNMARKED_ORDER" | tr '\n' ' ' | sed 's/ $//')"

echo "== run_test =="

PASSING="$(make_stub passing 0 0)"
FAILING="$(make_stub failing 1 0)"
HANGING="$(make_stub hanging 0 30)"

run_test "$PASSING" "$WORK/passing.log" "$WORK/passing.duration"
check "run_test returns 0 for a passing test" "0" "$?"
PASS_DURATION="$(cat "$WORK/passing.duration")"
check "run_test records a non-negative duration" "yes" "$([ "$PASS_DURATION" -ge 0 ] && echo yes || echo no)"

run_test "$FAILING" "$WORK/failing.log" "$WORK/failing.duration"
check "run_test returns non-zero for a failing test" "1" "$?"

SAVED_TIMEOUT="$PER_TEST_TIMEOUT"
PER_TEST_TIMEOUT=1
run_test "$HANGING" "$WORK/hanging.log" "$WORK/hanging.duration"
HANGING_STATUS=$?
PER_TEST_TIMEOUT="$SAVED_TIMEOUT"
check "run_test kills a test that exceeds the timeout" "yes" "$([ "$HANGING_STATUS" -ne 0 ] && echo yes || echo no)"

echo "== run_worker exclusivity =="

# Two workers over two .exclusive tests must never overlap.
EXCLUSIVE_COUNTER="$(make_counter_dir exclusive)"
EXCLUSIVE_ONE="$(make_concurrency_stub exclusive-one "$EXCLUSIVE_COUNTER" .exclusive)"
EXCLUSIVE_TWO="$(make_concurrency_stub exclusive-two "$EXCLUSIVE_COUNTER" .exclusive)"
RESULTS="$WORK/results-exclusive"
mkdir -p "$RESULTS"
RUNNER_SLOTS=("" "")
run_pool "$RESULTS" "$EXCLUSIVE_ONE" "$EXCLUSIVE_TWO" >/dev/null 2>&1
check "two .exclusive tests never run at the same time" "1" "$(cat "$EXCLUSIVE_COUNTER/max")"

# The same two workers over non-exclusive tests must overlap, proving the lock is not accidentally
# serialising everything.
SHARED_COUNTER="$(make_counter_dir shared)"
SHARED_ONE="$(make_concurrency_stub shared-one "$SHARED_COUNTER")"
SHARED_TWO="$(make_concurrency_stub shared-two "$SHARED_COUNTER")"
RESULTS="$WORK/results-shared"
mkdir -p "$RESULTS"
RUNNER_SLOTS=("" "")
run_pool "$RESULTS" "$SHARED_ONE" "$SHARED_TWO" >/dev/null 2>&1
check "two ordinary tests do run at the same time" "2" "$(cat "$SHARED_COUNTER/max")"

echo "== claim_device_slots =="

# Claims must be exclusive across processes: a second run may only take what the first left free.
export PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT=4
CLAIM_HELPER="$WORK/claim.sh"
# First argument is how long to keep holding the claim, so a test can outlast another run's
# claim timeout and prove the wait really does give up.
cat > "$CLAIM_HELPER" <<HELPER
#!/bin/bash
RED=''; GREEN=''; BLUE=''; NC=''
log_info() { :; }
source "$HERE/lib/runner.sh"
hold="\$1"
shift
if claim_device_slots "\$@"; then
    printf '%s\n' "\${CLAIMED_SLOTS[@]}"
else
    echo "TIMEOUT"
fi
sleep "\$hold"
HELPER
chmod +x "$CLAIM_HELPER"

rm -f /tmp/photosphere-android-device-fakedev-*.lock
# Held for 12s, well past the 4s claim timeout, so the waiting run must give up rather than
# eventually inheriting the devices when the holder happens to finish.
"$CLAIM_HELPER" 12 fakedev-a fakedev-b > "$WORK/claim-first" 2>/dev/null &
first_pid=$!
for _ in $(seq 1 40); do [ -s "$WORK/claim-first" ] && break; sleep 0.1; done
"$CLAIM_HELPER" 0 fakedev-a fakedev-b > "$WORK/claim-second" 2>/dev/null
check "the first run claims both free devices" "fakedev-a fakedev-b" "$(tr '\n' ' ' < "$WORK/claim-first" | sed 's/ $//')"
check "the second run gets nothing while both are held" "TIMEOUT" "$(cat "$WORK/claim-second")"

wait "$first_pid" 2>/dev/null

# A run takes only what is free, leaving the rest to whoever holds them. Separate device names from
# the scenario above, so a lingering holder there cannot skew this one.
"$CLAIM_HELPER" 8 fakedev-c > "$WORK/claim-holder" 2>/dev/null &
holder_pid=$!
for _ in $(seq 1 60); do [ -s "$WORK/claim-holder" ] && break; sleep 0.1; done
"$CLAIM_HELPER" 0 fakedev-c fakedev-d > "$WORK/claim-partial" 2>/dev/null
check "a run claims only the devices left free" "fakedev-d" "$(tr '\n' ' ' < "$WORK/claim-partial" | sed 's/ $//')"
wait "$holder_pid" 2>/dev/null

# Once the holders exit their descriptors close, so the devices become claimable again.
"$CLAIM_HELPER" 0 fakedev-a fakedev-b > "$WORK/claim-third" 2>/dev/null
check "devices are claimable again after the holder exits" "fakedev-a fakedev-b" "$(tr '\n' ' ' < "$WORK/claim-third" | sed 's/ $//')"
rm -f /tmp/photosphere-android-device-fakedev-*.lock
unset PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT

echo "== run_pool =="

ALL_PASS_ONE="$(make_stub pool-pass-one 0 0)"
ALL_PASS_TWO="$(make_stub pool-pass-two 0 0)"
RESULTS="$WORK/results-pass"
mkdir -p "$RESULTS"
RUNNER_SLOTS=("" "")
run_pool "$RESULTS" "$ALL_PASS_ONE" "$ALL_PASS_TWO" >/dev/null 2>&1
check "run_pool returns 0 when every test passes" "0" "$?"
check "run_pool ran every test exactly once" "2" "$(ls "$RESULTS" | wc -l)"

MIXED_PASS="$(make_stub pool-mixed-pass 0 0)"
MIXED_FAIL="$(make_stub pool-mixed-fail 1 0)"
RESULTS="$WORK/results-mixed"
mkdir -p "$RESULTS"
RUNNER_SLOTS=("" "")
run_pool "$RESULTS" "$MIXED_PASS" "$MIXED_FAIL" >/dev/null 2>&1
check "run_pool returns non-zero when a test fails" "1" "$?"
check "run_pool records a fail verdict" "1" "$(grep -lc '^fail ' "$RESULTS"/*.result 2>/dev/null | wc -l)"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "All runner tests passed."
    exit 0
fi
echo "$fails runner test(s) failed."
exit 1
