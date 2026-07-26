#!/bin/bash

# Work queue and worker pool for the mobile smoke tests.
#
# The suite used to run strictly one test at a time against one device. This spreads the tests over
# every device the run was given (one worker per device), pulling from a single shared queue so a
# fast worker keeps taking work instead of idling behind a slow one.
#
# Two markers in a test's directory control scheduling (see tests/README.md):
#   .exclusive  Only one such test runs at a time across the whole pool. The LAN-share tests need
#               this: discovery is a UDP broadcast on the segment every emulator shares, so two of
#               them running at once see each other's traffic.
#   .slow       Ordered to the front, so the longest test starts immediately rather than being the
#               last thing left running while every other worker sits idle.

# Marker file names, matched against a test's own directory.
SLOW_MARKER=".slow"
EXCLUSIVE_MARKER=".exclusive"

# Seconds a single test may run before the pool kills it, so one wedged test cannot hang the suite.
PER_TEST_TIMEOUT="${PHOTOSPHERE_PER_TEST_TIMEOUT:-600}"

# The device slots the pool runs on, one worker per entry. run.sh fills this from
# ${PLATFORM}_device_slots; the runner's own tests set it directly. A single empty entry means "one
# worker, no device binding".
RUNNER_SLOTS=()

# Set to 1 by run_pool when there is only one worker, so a single-device run keeps streaming test
# output to the terminal exactly as it did before the pool existed. With several workers the output
# would interleave into nonsense, so it goes to per-test log files instead.
RUNNER_STREAM_OUTPUT=0

# File descriptors used for the two locks. Deliberately NOT 9: run.sh is exec'd by android-lock.sh,
# which holds the machine-wide run lock open on fd 9 for the whole life of this process. Reusing it
# here would close that lock and let a second test:and run start on top of this one.
QUEUE_LOCK_FD=7
EXCLUSIVE_LOCK_FD=6

# File descriptors of the per-device locks this run holds. Kept open for the run's whole life,
# because a flock is released the moment its descriptor closes.
CLAIMED_DEVICE_FDS=()

# How long a run waits for at least one device to come free before giving up.
DEVICE_CLAIM_TIMEOUT="${PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT:-1800}"

# The devices this run claimed. Set by claim_device_slots.
CLAIMED_SLOTS=()

#
# Claims whichever of the given devices are not already in use by another run, leaving them in
# CLAIMED_SLOTS. Each claim is a non-blocking flock on a per-device lock file held open for the rest
# of the run, so two suites running at once take disjoint devices instead of colliding on the same
# emulator. Waits until at least one device is free rather than failing immediately.
#
# The result comes back in a global rather than on stdout deliberately: a flock lives only as long as
# its file descriptor, and calling this through `$(...)` or a process substitution would run it in a
# subshell whose descriptors close on exit, releasing every lock the moment it returned.
# Usage: claim_device_slots <serial...>
#
claim_device_slots() {
    local waited=0
    while true; do
        local slot fd
        CLAIMED_SLOTS=()
        for slot in "$@"; do
            exec {fd}<>"/tmp/photosphere-android-device-$slot.lock"
            if flock -n "$fd"; then
                CLAIMED_SLOTS+=("$slot")
                CLAIMED_DEVICE_FDS+=("$fd")
            else
                exec {fd}>&-
            fi
        done

        if [ ${#CLAIMED_SLOTS[@]} -gt 0 ]; then
            return 0
        fi

        if [ "$waited" -ge "$DEVICE_CLAIM_TIMEOUT" ]; then
            return 1
        fi
        if [ "$waited" -eq 0 ]; then
            log_info "Every device is busy with another run; waiting for one to come free..."
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

#
# Writes the work list, one test path per line, replacing anything already there.
# Usage: queue_init <queue_file> <test_path...>
#
queue_init() {
    local queue_file="$1"
    shift
    : > "$queue_file"
    local test_path
    for test_path in "$@"; do
        printf '%s\n' "$test_path" >> "$queue_file"
    done
}

#
# Prints and removes the first entry in the queue, or prints nothing when the queue is empty or
# absent. The whole read-modify-write happens under an exclusive flock on a sidecar lock file, so
# two workers popping at the same instant can never be handed the same test. This is the only place
# the queue file is mutated.
# Usage: queue_pop <queue_file>
#
queue_pop() {
    local queue_file="$1"
    if [ ! -f "$queue_file" ]; then
        return 0
    fi

    eval "exec $QUEUE_LOCK_FD<>\"\$queue_file.lock\""
    flock "$QUEUE_LOCK_FD"

    local first=""
    if [ -s "$queue_file" ]; then
        first="$(head -1 "$queue_file")"
        tail -n +2 "$queue_file" > "$queue_file.next"
        mv "$queue_file.next" "$queue_file"
    fi

    flock -u "$QUEUE_LOCK_FD"
    eval "exec $QUEUE_LOCK_FD>&-"

    if [ -n "$first" ]; then
        printf '%s\n' "$first"
    fi
    return 0
}

#
# Returns 0 when the test's own directory contains the named marker file.
# Usage: test_has_marker <test_path> <marker_name>
#
test_has_marker() {
    local test_path="$1"
    local marker="$2"
    [ -f "$(dirname "$test_path")/$marker" ]
}

#
# Prints the tests with the .slow-marked ones first, otherwise preserving the given order.
# Usage: order_tests <test_path...>
#
order_tests() {
    local slow=()
    local rest=()
    local test_path
    for test_path in "$@"; do
        if test_has_marker "$test_path" "$SLOW_MARKER"; then
            slow+=("$test_path")
        else
            rest+=("$test_path")
        fi
    done

    # Printed separately, and only when non-empty: `printf '%s\n' "${empty[@]}"` under `set -u`
    # either errors or emits a spurious blank line, which would become a bogus queue entry.
    if [ ${#slow[@]} -gt 0 ]; then
        printf '%s\n' "${slow[@]}"
    fi
    if [ ${#rest[@]} -gt 0 ]; then
        printf '%s\n' "${rest[@]}"
    fi
}

#
# Runs one test under a timeout, recording how long it took. Returns the test's exit status.
# Usage: run_test <test_path> <log_file> <duration_file>
#
run_test() {
    local test_path="$1"
    local log_file="$2"
    local duration_file="$3"
    local start="$SECONDS"
    local status=0

    if [ "$RUNNER_STREAM_OUTPUT" = "1" ]; then
        timeout "$PER_TEST_TIMEOUT" bash "$test_path" 2>&1 | tee "$log_file"
        status="${PIPESTATUS[0]}"
    else
        timeout "$PER_TEST_TIMEOUT" bash "$test_path" > "$log_file" 2>&1
        status=$?
    fi

    echo $((SECONDS - start)) > "$duration_file"
    return "$status"
}

#
# One worker: binds itself to a device slot, then loops popping tests until the queue is empty.
# An .exclusive-marked test is run while holding the pool-wide exclusive lock, so at most one of
# them is ever in flight no matter how many workers there are. Each test's verdict is written to its
# own file in the results directory, so concurrent workers never interleave a shared results file.
# Usage: run_worker <slot> <queue_file> <exclusive_lock_file> <results_dir>
#
run_worker() {
    local slot="$1"
    local queue_file="$2"
    local exclusive_lock="$3"
    local results_dir="$4"

    # An empty slot means the caller is not binding this worker to a device (the runner's own tests,
    # and any platform with a single implicit device).
    if [ -n "$slot" ]; then
        "${PLATFORM}_export_device" "$slot"
    fi

    while true; do
        local test_path
        test_path="$(queue_pop "$queue_file")"
        if [ -z "$test_path" ]; then
            break
        fi

        local dir name log_file duration_file
        dir="$(dirname "$test_path")"
        name="$(basename "$dir")"
        rm -rf "$dir/tmp"
        mkdir -p "$dir/tmp"
        log_file="$dir/tmp/test-run.log"
        duration_file="$dir/tmp/test-duration.txt"

        printf "${BLUE}RUN ${NC}  %s\n" "$name"

        local status=0
        if test_has_marker "$test_path" "$EXCLUSIVE_MARKER"; then
            eval "exec $EXCLUSIVE_LOCK_FD<>\"\$exclusive_lock\""
            flock "$EXCLUSIVE_LOCK_FD"
            run_test "$test_path" "$log_file" "$duration_file" || status=$?
            flock -u "$EXCLUSIVE_LOCK_FD"
            eval "exec $EXCLUSIVE_LOCK_FD>&-"
        else
            run_test "$test_path" "$log_file" "$duration_file" || status=$?
        fi

        local duration
        duration="$(cat "$duration_file" 2>/dev/null || echo 0)"
        if [ "$status" -eq 0 ]; then
            printf "${GREEN}PASS${NC}  %-32s  %ss\n" "$name" "$duration"
            echo "pass $name $duration" > "$results_dir/$name.result"
        else
            printf "${RED}FAIL${NC}  %-32s  %ss  (log: %s)\n" "$name" "$duration" "$log_file"
            echo "fail $name $duration" > "$results_dir/$name.result"
        fi
    done
}

#
# Runs every given test across the device slots in RUNNER_SLOTS, one worker per slot. Returns
# non-zero if any test failed. The queue and the exclusive lock live in a temp directory that is
# removed when the pool finishes.
# Usage: run_pool <results_dir> <test_path...>
#
run_pool() {
    local results_dir="$1"
    shift

    if [ ${#RUNNER_SLOTS[@]} -eq 0 ]; then
        RUNNER_SLOTS=("")
    fi

    # A single worker keeps the pre-pool behaviour of streaming each test's output to the terminal.
    if [ ${#RUNNER_SLOTS[@]} -le 1 ]; then
        RUNNER_STREAM_OUTPUT=1
    else
        RUNNER_STREAM_OUTPUT=0
    fi

    local work_dir queue_file exclusive_lock
    work_dir="$(mktemp -d)"
    queue_file="$work_dir/queue"
    exclusive_lock="$work_dir/exclusive.lock"
    : > "$exclusive_lock"
    queue_init "$queue_file" "$@"
    mkdir -p "$results_dir"

    local pids=()
    local slot
    for slot in "${RUNNER_SLOTS[@]}"; do
        run_worker "$slot" "$queue_file" "$exclusive_lock" "$results_dir" &
        pids+=($!)
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    rm -rf "$work_dir"

    # The verdict comes from the result files, not the workers' exit statuses: a worker exits 0 when
    # it drains the queue, whatever the tests it ran did.
    if grep -lq '^fail ' "$results_dir"/*.result 2>/dev/null; then
        return 1
    fi
    return 0
}
