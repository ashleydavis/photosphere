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

# How many tests a suite adds to its in-flight set at a time when it is competing with other suites.
# This is a scheduling batch, NOT a cap on how many emulators a suite may use: a suite running on its
# own keeps submitting until every emulator is busy. It only matters when suites compete, where it is
# the floor each one is guaranteed.
TEST_BATCH="${PHOTOSPHERE_TEST_BATCH:-2}"

# Where running suites register themselves, so each one can see how many others it is sharing the
# emulators with and take its fair share. One file per suite, named for its process id.
SUITE_REGISTRY_DIR="/tmp/photosphere-android-suites"

# This suite's registration file and the count of emulators it currently holds. The count is shared
# between the suite's workers, which are separate processes, so it lives in a file guarded by a lock.
SUITE_REGISTRATION=""
SUITE_HELD_FILE=""
SUITE_HELD_LOCK=""

#
# Registers this suite so others can see it, and arranges for it to be deregistered on exit. Until
# this runs a suite is invisible and the others will over-commit.
#
register_suite() {
    mkdir -p "$SUITE_REGISTRY_DIR"
    SUITE_REGISTRATION="$SUITE_REGISTRY_DIR/$$"
    SUITE_HELD_FILE="$SUITE_REGISTRY_DIR/$$.held"
    SUITE_HELD_LOCK="$SUITE_REGISTRY_DIR/$$.held.lock"
    echo "$$" > "$SUITE_REGISTRATION"
    echo 0 > "$SUITE_HELD_FILE"
    : > "$SUITE_HELD_LOCK"
}

#
# Removes this suite's registration and counters. Safe to call more than once.
#
deregister_suite() {
    if [ -n "$SUITE_REGISTRATION" ]; then
        rm -f "$SUITE_REGISTRATION" "$SUITE_HELD_FILE" "$SUITE_HELD_LOCK"
        SUITE_REGISTRATION=""
    fi
}

#
# Prints how many suites are currently running, clearing out any registration whose process has died
# so a crashed suite cannot permanently shrink everyone else's share.
#
active_suite_count() {
    local registration pid count=0
    for registration in "$SUITE_REGISTRY_DIR"/*; do
        case "$registration" in
            *.held|*.held.lock|*"*")
                continue
                ;;
        esac
        pid="$(basename "$registration")"
        if [ -d "/proc/$pid" ]; then
            count=$((count + 1))
        else
            rm -f "$registration" "$registration.held" "$registration.held.lock" 2>/dev/null || true
        fi
    done
    if [ "$count" -lt 1 ]; then
        count=1
    fi
    echo "$count"
}

#
# Prints how many emulators this suite may hold right now: an even split of the emulators between the
# running suites, never less than one.
#
# This is what keeps every emulator busy while still being fair. Alone, a suite's share is all of
# them. With three suites on six emulators it is two each, which is where the batch size comes from,
# but that falls out of the arithmetic rather than being imposed. When a suite finishes, the others'
# shares grow on their next check, so the emulators it frees are picked straight back up.
#
suite_share() {
    local suites share
    suites="$(active_suite_count)"
    share=$(( ${#RUNNER_SLOTS[@]} / suites ))
    if [ "$share" -lt 1 ]; then
        share=1
    fi
    echo "$share"
}

#
# Adds to this suite's held-emulator count and prints the new value, under a lock so its workers
# cannot race each other. Usage: adjust_held <delta>
#
adjust_held() {
    local delta="$1"
    local fd held
    exec {fd}<>"$SUITE_HELD_LOCK"
    flock "$fd"
    held=$(( $(cat "$SUITE_HELD_FILE" 2>/dev/null || echo 0) + delta ))
    if [ "$held" -lt 0 ]; then
        held=0
    fi
    echo "$held" > "$SUITE_HELD_FILE"
    exec {fd}>&-
    echo "$held"
}

# Every device this run may dispatch a test to. run.sh fills this from ${PLATFORM}_device_slots; the
# runner's own tests set it directly. A single empty entry means "no device binding".
RUNNER_SLOTS=()

# The emulators are shared by every suite on the machine, so the lock that serialises .exclusive
# tests has to be at a fixed path rather than inside one run's temp directory. Two suites both
# running a LAN test would otherwise broadcast over each other on the shared bridge.
EXCLUSIVE_LOCK_FILE="/tmp/photosphere-android-exclusive.lock"

# Serialises the build between suites running out of the SAME checkout. `cap sync` deletes and
# rewrites files under that checkout's android project directory
# (capacitor-cordova-android-plugins/build.gradle among them), so two suites building there at once
# make each other's build fail with ENOENT. Suites that wait find the build already up to date, so
# they pay very little for it.
#
# Keyed on the checkout, not the machine: two worktrees have separate project directories and cannot
# corrupt each other's build, so making them queue would cost time for nothing.
BUILD_LOCK_FILE="/tmp/photosphere-android-build-$(printf '%s' "$REPO_DIR" | md5sum | cut -c1-12).lock"

# Per-test scratch directory for this run, relative to each test's own directory. Concurrent runs out
# of one checkout must not share it: the wipe before each test would otherwise delete a live bridge
# log and pid file belonging to another run. Set from PHOTOSPHERE_TEST_TMP when a run id was handed
# down, else plain "tmp" as a single run has always used.
RUN_TMP_NAME="${PHOTOSPHERE_TEST_TMP:-tmp}"

# Set to 1 by run_pool when there is only one worker, so a single-device run keeps streaming test
# output to the terminal exactly as it did before the pool existed. With several workers the output
# would interleave into nonsense, so it goes to per-test log files instead.
RUNNER_STREAM_OUTPUT=0

# File descriptors used for the two locks. Deliberately NOT 9: run.sh is exec'd by android-lock.sh,
# which holds the machine-wide run lock open on fd 9 for the whole life of this process. Reusing it
# here would close that lock and let a second test:and run start on top of this one.
QUEUE_LOCK_FD=7
EXCLUSIVE_LOCK_FD=6

# How long a worker waits for an emulator to come free before giving up on its test.
DEVICE_CLAIM_TIMEOUT="${PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT:-1800}"

# The device the calling worker currently holds, and the descriptor holding its lock. Set by
# acquire_device, cleared by release_device.
ACQUIRED_DEVICE=""
ACQUIRED_FD=""

#
# Takes the first emulator in RUNNER_SLOTS that no other worker, in this suite or any other, is
# using, and leaves it in ACQUIRED_DEVICE. Blocks until one comes free, giving up after
# DEVICE_CLAIM_TIMEOUT.
#
# A device is claimed for the length of one test, not for the length of a run. That is what lets
# several suites share the emulators: each suite only ever holds as many as it has tests in flight,
# so devices are handed back between tests instead of being reserved up front.
#
# The result comes back in globals rather than on stdout deliberately: a flock lives only as long as
# its file descriptor, so returning it through $(...) or a process substitution would run this in a
# subshell whose descriptors close on return, releasing the lock immediately.
#
acquire_device() {
    local waited=0
    while true; do
        # Only reach for another emulator while this suite is under its fair share, so a suite
        # cannot take the lot and starve the others. The share is recalculated every pass, so it
        # grows the moment another suite finishes and shrinks when a new one starts.
        local held share
        held="$(cat "$SUITE_HELD_FILE" 2>/dev/null || echo 0)"
        share="$(suite_share)"
        if [ "$held" -lt "$share" ]; then
            local serial fd
            for serial in "${RUNNER_SLOTS[@]}"; do
                # An empty slot means the caller is not binding tests to devices at all, so there is
                # nothing to lock.
                if [ -z "$serial" ]; then
                    ACQUIRED_DEVICE=""
                    ACQUIRED_FD=""
                    return 0
                fi
                exec {fd}<>"/tmp/photosphere-android-device-$serial.lock"
                if flock -n "$fd"; then
                    ACQUIRED_DEVICE="$serial"
                    ACQUIRED_FD="$fd"
                    adjust_held 1 >/dev/null
                    return 0
                fi
                exec {fd}>&-
            done
        fi

        if [ "$waited" -ge "$DEVICE_CLAIM_TIMEOUT" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

#
# Runs a command bound to one named emulator while holding that emulator's lock, waiting if another
# suite is mid-test on it. Used for the install and the cleanup, which reinstall the app and wipe its
# data: doing either underneath a test another suite is running would break that test.
# Usage: with_device <serial> <command...>
#
with_device() {
    local serial="$1"
    shift

    # No serial means the caller is not binding to devices at all.
    if [ -z "$serial" ]; then
        "$@"
        return $?
    fi

    local fd status=0
    exec {fd}<>"/tmp/photosphere-android-device-$serial.lock"
    flock "$fd"
    "${PLATFORM}_export_device" "$serial"
    # Closed for the command and its children, so nothing it spawns can outlive it still holding the
    # device locked. See the note in run_worker.
    "$@" {fd}>&- || status=$?
    exec {fd}>&-
    return "$status"
}

#
# Runs a command while holding the machine-wide build lock, so only one suite builds at a time.
# Usage: with_build_lock <command...>
#
with_build_lock() {
    local fd status=0
    exec {fd}<>"$BUILD_LOCK_FILE"
    if ! flock -n "$fd"; then
        log_info "Another suite is building; waiting for it to finish..."
        flock "$fd"
    fi
    # Closed for the build and its children, for the same reason as the device locks.
    "$@" {fd}>&- || status=$?
    exec {fd}>&-
    return "$status"
}

#
# Hands the current worker's emulator back, so another worker in this suite or another suite can take
# it. Closing the descriptor is what releases the flock.
#
release_device() {
    if [ -n "$ACQUIRED_FD" ]; then
        exec {ACQUIRED_FD}>&-
        ACQUIRED_FD=""
        adjust_held -1 >/dev/null
    fi
    ACQUIRED_DEVICE=""
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
# Runs one test with the runner's lock descriptors closed for it and everything it spawns.
#
# A test starts the control bridge as a background process that outlives it, and a child inherits the
# parent's open file descriptions, flocks included. An inherited copy kept a device locked long after
# the test had finished, so concurrent suites deadlocked waiting on emulators nothing was using.
# Closing them here leaves this shell's own copies, which are what actually hold the locks.
#
# The device descriptor is only closed when one is held: `{var}>&-` with an empty var is an
# ambiguous redirect, which would stop the test running at all. Closing the fixed exclusive-lock
# descriptor is safe whether or not it is open.
# Usage: run_test_isolated <test_path> <log_file> <duration_file>
#
run_test_isolated() {
    if [ -n "$ACQUIRED_FD" ]; then
        run_test "$1" "$2" "$3" {ACQUIRED_FD}>&- 6>&-
        return $?
    fi
    run_test "$1" "$2" "$3" 6>&-
}

#
# One worker: loops popping tests until the queue is empty, taking an emulator for each test and
# handing it straight back afterwards. There is a worker per emulator, so a suite on its own fills
# every one; when suites compete, acquire_device holds each to its fair share.
#
# An .exclusive-marked test is run while holding the machine-wide exclusive lock, so at most one of
# them is in flight across every suite on the machine. Each test's verdict is written to its own file
# in the results directory, so concurrent workers never interleave a shared results file.
# Usage: run_worker <queue_file> <exclusive_lock_file> <results_dir>
#
run_worker() {
    local queue_file="$1"
    local exclusive_lock="$2"
    local results_dir="$3"

    while true; do
        local test_path
        test_path="$(queue_pop "$queue_file")"
        if [ -z "$test_path" ]; then
            break
        fi

        local dir name log_file duration_file
        dir="$(dirname "$test_path")"
        name="$(basename "$dir")"
        # Scoped to this run, so wiping it cannot destroy a concurrent run's live test state.
        rm -rf "$dir/$RUN_TMP_NAME"
        mkdir -p "$dir/$RUN_TMP_NAME"
        log_file="$dir/$RUN_TMP_NAME/test-run.log"
        duration_file="$dir/$RUN_TMP_NAME/test-duration.txt"

        # Wait for a free emulator, then bind this test to it. Held only while the test runs.
        if ! acquire_device; then
            printf "${RED}FAIL${NC}  %-32s  no emulator came free within %ss\n" "$name" "$DEVICE_CLAIM_TIMEOUT"
            echo "fail $name 0" > "$results_dir/$name.result"
            continue
        fi
        if [ -n "$ACQUIRED_DEVICE" ]; then
            "${PLATFORM}_export_device" "$ACQUIRED_DEVICE"
            # Another checkout's suite may have installed its own build on this device since this
            # run last used it. Put this run's APK back before testing, while its lock is held, so a
            # test can never execute somebody else's code.
            "${PLATFORM}_ensure_apk"
            printf "${BLUE}RUN ${NC}  %-32s  %s\n" "$name" "$ACQUIRED_DEVICE"
        else
            printf "${BLUE}RUN ${NC}  %s\n" "$name"
        fi

        local status=0
        if test_has_marker "$test_path" "$EXCLUSIVE_MARKER"; then
            eval "exec $EXCLUSIVE_LOCK_FD<>\"\$exclusive_lock\""
            flock "$EXCLUSIVE_LOCK_FD"
            run_test_isolated "$test_path" "$log_file" "$duration_file" || status=$?
            flock -u "$EXCLUSIVE_LOCK_FD"
            eval "exec $EXCLUSIVE_LOCK_FD>&-"
        else
            run_test_isolated "$test_path" "$log_file" "$duration_file" || status=$?
        fi

        release_device

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

    # One worker per emulator, so a suite running on its own can fill every one of them. What a suite
    # actually holds at any moment is bounded by its fair share, not by the worker count: with other
    # suites running, the surplus workers simply wait in acquire_device until the share allows more.
    local workers=${#RUNNER_SLOTS[@]}
    if [ "$workers" -lt 1 ]; then
        workers=1
    fi

    register_suite

    # A single worker keeps the pre-pool behaviour of streaming each test's output to the terminal.
    if [ "$workers" -le 1 ]; then
        RUNNER_STREAM_OUTPUT=1
    else
        RUNNER_STREAM_OUTPUT=0
    fi

    local work_dir queue_file exclusive_lock
    work_dir="$(mktemp -d)"
    queue_file="$work_dir/queue"
    exclusive_lock="$EXCLUSIVE_LOCK_FILE"
    touch "$exclusive_lock" 2>/dev/null || true
    queue_init "$queue_file" "$@"
    mkdir -p "$results_dir"

    log_info "Using up to ${#RUNNER_SLOTS[@]} emulator(s); currently sharing with $(active_suite_count) suite(s), so this one's share is $(suite_share)."

    local pids=()
    local worker
    for worker in $(seq 1 "$workers"); do
        run_worker "$queue_file" "$exclusive_lock" "$results_dir" &
        pids+=($!)
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    rm -rf "$work_dir"

    # Stand down, so the suites still running widen their share and pick up the emulators this one
    # was using.
    deregister_suite

    # The verdict comes from the result files, not the workers' exit statuses: a worker exits 0 when
    # it drains the queue, whatever the tests it ran did.
    if grep -lq '^fail ' "$results_dir"/*.result 2>/dev/null; then
        return 1
    fi
    return 0
}
