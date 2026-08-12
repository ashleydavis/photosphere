#!/usr/bin/env bash
# Tests lib/runner.sh: the work queue, the test filter, and the worker pool.
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
# and prints the path.
# Usage: make_stub <name> <exit_status> <sleep_seconds>
#
make_stub() {
    local name="$1"
    local exit_status="$2"
    local sleep_seconds="$3"
    local dir="$WORK/tests/$name"
    mkdir -p "$dir"
    {
        echo '#!/bin/bash'
        echo "sleep $sleep_seconds"
        echo "exit $exit_status"
    } > "$dir/test.sh"
    echo "$dir/test.sh"
}

#
# Creates a stub that records concurrent execution: it bumps a counter under a lock on entry, notes
# the high-water mark, sleeps, then decrements. Lets a test prove whether two stubs ever overlapped.
# Usage: make_concurrency_stub <name> <counter_dir>
#
make_concurrency_stub() {
    local name="$1"
    local counter_dir="$2"
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

echo "== test_matches_filter =="

test_matches_filter "2-create-database" ""
check "an empty filter selects every test" "0" "$?"

test_matches_filter "2-create-database" "2"
check "a number selects the test with that number" "0" "$?"
test_matches_filter "12-edit-api-key" "2"
check "a number does not select a test whose number merely contains it" "1" "$?"
test_matches_filter "22-edit-database-origin" "2"
check "a number does not select a test whose number repeats it" "1" "$?"
test_matches_filter "29-stale-recent-database" "29"
check "a two digit number selects the test with that number" "0" "$?"
test_matches_filter "2-create-database" "02"
check "a leading zero on the filter still matches, and is not read as octal" "0" "$?"
test_matches_filter "8-share-database" "2"
check "a number does not select a test whose name contains it elsewhere" "1" "$?"

# 17 is used by two tests, so a numeric filter is allowed to select more than one.
test_matches_filter "17-news-notifications" "17"
check "a shared number selects the first test using it" "0" "$?"
test_matches_filter "17-replicate-database" "17"
check "a shared number selects the second test using it too" "0" "$?"

test_matches_filter "29-stale-recent-database" "29-stale-recent-database"
check "a full name selects that test" "0" "$?"
test_matches_filter "29-stale-recent-database" "stale-recent"
check "part of a name selects that test" "0" "$?"
test_matches_filter "29-stale-recent-database" "STALE"
check "a name filter ignores case" "0" "$?"
test_matches_filter "2-create-database" "stale-recent"
check "a name filter does not select an unrelated test" "1" "$?"
test_matches_filter "2-create-database" "nonexistent"
check "a name filter that matches nothing selects nothing" "1" "$?"

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

echo "== run_worker concurrency =="

# Two workers must actually overlap: nothing serialises tests any more, so a pool with two slots has
# to have both of them running at once.
SHARED_COUNTER="$(make_counter_dir shared)"
SHARED_ONE="$(make_concurrency_stub shared-one "$SHARED_COUNTER")"
SHARED_TWO="$(make_concurrency_stub shared-two "$SHARED_COUNTER")"
RESULTS="$WORK/results-shared"
mkdir -p "$RESULTS"
RUNNER_SLOTS=("" "")
run_pool "$RESULTS" "$SHARED_ONE" "$SHARED_TWO" >/dev/null 2>&1
check "two ordinary tests do run at the same time" "2" "$(cat "$SHARED_COUNTER/max")"

echo "== acquire_device / release_device =="

export PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT=4
ACQUIRE_HELPER="$WORK/acquire.sh"
# Takes a hold duration then the device list, so a test can keep a device occupied while another
# process tries for it.
cat > "$ACQUIRE_HELPER" <<HELPER
#!/bin/bash
RED=''; GREEN=''; BLUE=''; NC=''
log_info() { :; }
source "$HERE/lib/runner.sh"
hold="\$1"
shift
RUNNER_SLOTS=("\$@")
if acquire_device; then
    echo "\$ACQUIRED_DEVICE"
else
    echo "TIMEOUT"
fi
sleep "\$hold"
release_device
HELPER
chmod +x "$ACQUIRE_HELPER"

rm -f /tmp/photosphere-android-device-fakedev-*.lock

RUNNER_SLOTS=(fakedev-a fakedev-b)
acquire_device
check "acquire_device takes the first free device" "fakedev-a" "$ACQUIRED_DEVICE"
release_device
check "release_device clears the held device" "" "$ACQUIRED_DEVICE"

# A device held by another process is skipped, not waited for, while others are free.
"$ACQUIRE_HELPER" 8 fakedev-a > "$WORK/acq-holder" 2>/dev/null &
holder_pid=$!
for _ in $(seq 1 60); do [ -s "$WORK/acq-holder" ] && break; sleep 0.1; done
"$ACQUIRE_HELPER" 0 fakedev-a fakedev-b > "$WORK/acq-second" 2>/dev/null
check "a busy device is skipped for a free one" "fakedev-b" "$(cat "$WORK/acq-second")"

# With every device busy, a further acquire waits and then gives up.
"$ACQUIRE_HELPER" 8 fakedev-b > "$WORK/acq-holder2" 2>/dev/null &
holder2_pid=$!
for _ in $(seq 1 60); do [ -s "$WORK/acq-holder2" ] && break; sleep 0.1; done
"$ACQUIRE_HELPER" 0 fakedev-a fakedev-b > "$WORK/acq-third" 2>/dev/null
check "acquire_device times out when every device is busy" "TIMEOUT" "$(cat "$WORK/acq-third")"
wait "$holder_pid" "$holder2_pid" 2>/dev/null

# Devices are handed back when a holder finishes, so the next taker gets one.
"$ACQUIRE_HELPER" 0 fakedev-a fakedev-b > "$WORK/acq-fourth" 2>/dev/null
check "a device is free again once its holder releases it" "fakedev-a" "$(cat "$WORK/acq-fourth")"

# Claiming and releasing the same single device over and over must keep working. Where there is no
# flock the claim takes no descriptor, and releasing keyed only off that descriptor left the suite's
# held count climbing: it then believed it was at its share and waited out the full claim timeout
# before every test after the first, which is hours rather than minutes. This walks several
# claim/release cycles on one device and fails if any of them stops handing the device back.
SUITE_HELD_FILE="$WORK/cycle-held"
SUITE_HELD_LOCK="$WORK/cycle-held.lock"
echo 0 > "$SUITE_HELD_FILE"
: > "$SUITE_HELD_LOCK"
SAVED_CLAIM_TIMEOUT="$DEVICE_CLAIM_TIMEOUT"
# Short, so a regression reports a failure in seconds instead of stalling this suite for half an hour.
DEVICE_CLAIM_TIMEOUT=3
CYCLE_OK="yes"
for cycle in 1 2 3; do
    RUNNER_SLOTS=("fakedev-cycle")
    if ! acquire_device; then
        CYCLE_OK="claim failed on cycle $cycle"
        break
    fi
    if [ "$ACQUIRED_DEVICE" != "fakedev-cycle" ]; then
        CYCLE_OK="wrong device on cycle $cycle: $ACQUIRED_DEVICE"
        break
    fi
    release_device
    if [ "$(cat "$SUITE_HELD_FILE" 2>/dev/null || echo 0)" != "0" ]; then
        CYCLE_OK="held count stuck at $(cat "$SUITE_HELD_FILE") after cycle $cycle"
        break
    fi
done
DEVICE_CLAIM_TIMEOUT="$SAVED_CLAIM_TIMEOUT"
check "repeated claim/release on one device always hands it back" "yes" "$CYCLE_OK"

rm -f /tmp/photosphere-android-device-fakedev-*.lock
unset PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT
RUNNER_SLOTS=()

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
