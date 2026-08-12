#!/bin/bash

# Work queue and worker pool for the mobile smoke tests.
#
# The suite used to run strictly one test at a time against one device. This spreads the tests over
# every device the run was given (one worker per device), pulling from a single shared queue so a
# fast worker keeps taking work instead of idling behind a slow one.
#
# Tests are dispatched in the order they are given, and nothing reorders or serialises them. Two
# LAN-share tests may therefore run at the same time on different emulators, which is safe because
# discovery is disambiguated by the pairing code rather than by scheduling: a sender ignores any
# receiver whose code hash is not its own (packages/lan-share-network/src/lib/lan-share-sender.ts),
# a receiver rejects a payload carrying the wrong code, and every test draws a random code.

# Directory holding this file, used to reach the shared per-test temp directory helpers.
RUNNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-test temporary directories. Sourced here as well as from common.sh because runner.test.sh
# sources this file on its own, without common.sh, and the worker loop below allocates a directory
# for every test it dispatches.
source "$RUNNER_LIB_DIR/../../../scripts/lib/allocate-test-temp-dir.sh"

# The per-test timeout every suite in this repository shares, and the reporting that goes with it.
source "$RUNNER_LIB_DIR/../../../scripts/lib/test-timeout.sh"

# The device lock path, from the one file that defines it. Sourced here rather than written out
# again, because the emulator repair path takes the same lock before it restarts an emulator and a
# second copy of the path that drifted would let it restart one mid-test.
source "$RUNNER_LIB_DIR/../../android-frontend/scripts/emulator-config.sh"

# Exit code a test uses to say it did not run its body, so the runner can report it as skipped rather
# than as a pass. Before this existed a gated test (no LAN bridge, or an Android-only test dispatched
# on iOS) exited 0 having executed nothing, and the runner counted it in "All N tests passed": the
# suite reported coverage it had not performed. 77 is the conventional skip code and is far enough
# from a real failure that nothing else produces it. common.sh defines the same value for the tests.
TEST_SKIPPED_EXIT_CODE=77

# Seconds a single test may run before the pool kills it, so one wedged test cannot hang the suite.
# The value comes from scripts/lib/test-timeout.sh, which every suite in this repository shares, so a
# mobile test and a CLI test are held to the same ceiling rather than to whatever each runner grew.
PER_TEST_TIMEOUT="$PHOTOSPHERE_PER_TEST_TIMEOUT"

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
        # /proc is Linux-only and there is none on macOS, where every registration would otherwise
        # look dead and be swept away on sight. Both checks are kept rather than swapping one for the
        # other, because neither is a superset: kill -0 works everywhere but says "dead" for a live
        # process belonging to another user, and /proc gets that case right on Linux.
        if kill -0 "$pid" 2>/dev/null || [ -d "/proc/$pid" ]; then
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
    # The descriptor exists only to be locked, so it is opened only where there is a lock to take.
    # bash 3.2, which is what /bin/bash is on macOS, has no {fd} allocation and fails on the line
    # itself, so this cannot simply be opened and left unlocked.
    if [ "$RUNNER_HAS_FLOCK" = "1" ]; then
        exec {fd}<>"$SUITE_HELD_LOCK"
        runner_flock "$fd"
    fi
    held=$(( $(cat "$SUITE_HELD_FILE" 2>/dev/null || echo 0) + delta ))
    if [ "$held" -lt 0 ]; then
        held=0
    fi
    echo "$held" > "$SUITE_HELD_FILE"
    if [ "$RUNNER_HAS_FLOCK" = "1" ]; then
        exec {fd}>&-
    fi
    echo "$held"
}

# Every device this run may dispatch a test to. run.sh fills this from ${PLATFORM}_device_slots; the
# runner's own tests set it directly. A single empty entry means "no device binding".
RUNNER_SLOTS=()

# Serialises the build between suites running out of the SAME checkout. `cap sync` deletes and
# rewrites files under that checkout's android project directory
# (capacitor-cordova-android-plugins/build.gradle among them), so two suites building there at once
# make each other's build fail with ENOENT. Suites that wait find the build already up to date, so
# they pay very little for it.
#
# Keyed on the checkout, not the machine: two worktrees have separate project directories and cannot
# corrupt each other's build, so making them queue would cost time for nothing.
# cksum rather than md5sum: md5sum is GNU coreutils and does not exist on macOS, where the iOS suite
# runs, so sourcing this file there died with "md5sum: command not found" before a single test ran.
# cksum is POSIX and present on both. It is only naming a lock file, so a weak hash is fine: the worst
# a collision does is make two unrelated checkouts queue behind each other's build.
BUILD_LOCK_FILE="/tmp/photosphere-android-build-$(printf '%s' "$REPO_DIR" | cksum | cut -d' ' -f1).lock"

# Whether this platform has flock(1). It is Linux-only; macOS, where the iOS suite runs, has no such
# command, so every lock below would fail there.
#
# Where it is missing the locks become no-ops rather than errors, which is what lets an iOS run work.
# That is only sound for a run with ONE worker. The build lock guards against concurrent suites and
# losing it merely costs correctness between runs,
# but the queue lock guards a read-modify-write between the workers of a SINGLE run: without it two
# workers pop the same entry and skip others, which the runner's own tests demonstrate. run.sh
# therefore refuses to start on more than one device when this is 0, rather than producing a run
# whose results cannot be trusted. An iOS run has a single simulator, so it is always in that case.
# Plain echo rather than log_info: runner.test.sh sources this file on its own, without common.sh,
# so log_info is not always defined by the time this runs. On stderr, because several functions here
# return their result on stdout and a caller capturing one must not capture this as well.
if command -v flock >/dev/null 2>&1; then
    RUNNER_HAS_FLOCK=1
else
    RUNNER_HAS_FLOCK=0
    echo "flock is not available on this platform; run-to-run device and build locking is disabled." >&2
fi


#
# flock(1) where it exists, a no-op where it does not. Takes flock's own arguments. Returning success
# when absent is what makes the callers degrade rather than fail: a non-blocking claim reports the
# device as taken, and a blocking wait returns immediately.
#
runner_flock() {
    if [ "$RUNNER_HAS_FLOCK" = "1" ]; then
        flock "$@"
        return $?
    fi
    return 0
}

# The address every device must be able to reach for any mobile test to work: this host, on the LAN
# bridge. Matches BRIDGE_HOST's reasoning in common.sh, from the guest's side rather than the host's.
DEVICE_HEALTH_HOST="192.168.55.1"

# How long a health probe is given before it counts as a failure, and how long a withdrawn device is
# left alone before being re-probed.
#
# 30s to recover rather than something shorter because these outages have been measured recovering on
# their own: one device lost its route to the host, kept its address, services and adb connection
# throughout, and was answering again minutes later. Re-probing too eagerly just burns adb calls.
DEVICE_HEALTH_TIMEOUT_SECONDS=10
DEVICE_RECOVERY_WAIT_SECONDS=30

# How often the link to the device is sampled while a test runs. Short enough to catch the
# one-to-four second outages that make up most of what has been measured.
DEVICE_HEALTH_SAMPLE_SECONDS=2

# How many times one test may be put back on the queue because the device under it went unreachable.
#
# Bounded on purpose. Without a cap, a pool that never recovers would hand the same test round for
# ever and the run would never end. When the cap is reached the test is recorded as a real failure,
# because at that point the evidence no longer says "the device was briefly unreachable", it says the
# test could not be run at all and somebody needs to know.
MAX_DEVICE_REQUEUES_PER_TEST=3

# Where withdrawn devices are recorded, one file per serial holding the time it was withdrawn. A file
# rather than a variable because the pool's workers are separate subshells and cannot share state any
# other way, which is the same reason the work queue and the held count are files.
RUNNER_QUARANTINE_DIR=""

# Set to 1 by run_pool when there is only one worker, so a single-device run keeps streaming test
# output to the terminal exactly as it did before the pool existed. With several workers the output
# would interleave into nonsense, so it goes to per-test log files instead.
RUNNER_STREAM_OUTPUT=0

# File descriptor used for the queue lock. Deliberately NOT 9: run.sh is exec'd by android-lock.sh,
# which holds the machine-wide run lock open on fd 9 for the whole life of this process. Reusing it
# here would close that lock and let a second test:and run start on top of this one.
QUEUE_LOCK_FD=7

# How long a worker waits for an emulator to come free before giving up on its test.
DEVICE_CLAIM_TIMEOUT="${PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT:-1800}"

# How long the install and cleanup steps wait for one device before giving it up and moving on.
# These run over every device in turn before any test starts, so an unbounded wait here stalls the
# whole suite on a single stuck device. Long enough that a device genuinely mid-test in another
# suite is waited for, short enough that a leaked lock costs one device rather than the run.
DEVICE_SETUP_LOCK_TIMEOUT="${PHOTOSPHERE_DEVICE_SETUP_LOCK_TIMEOUT:-120}"

# What with_device returns when it could not claim the device at all, as opposed to the status of a
# command that ran on it. Chosen outside the range a normal command returns so the two cannot be
# confused: a failed install must fail the run, an unavailable device must only lose that device.
DEVICE_UNAVAILABLE_STATUS=75

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
#
# Whether a device can still reach this host.
#
# Every mobile test depends on this and nothing else checks it: the app talks to the host's control
# bridge over the LAN bridge, so a device that cannot reach the host fails every test given to it
# while adb still reports it as present and healthy. Measured directly rather than inferred, and
# read-only: it pings and nothing else.
#
# The probe belongs to the platform, because only one of the two can answer it at all and the cost
# of answering wrongly is the whole run. A probe that always says "unreachable" withdraws the device
# under the first test that does not exit 0, and a run with one device then has none, so every
# remaining test waits DEVICE_CLAIM_TIMEOUT and the job dies on its own timeout with nothing to show.
# That is what the release workflow did on both mobile jobs.
#
# Usage: device_can_reach_host <serial>
#
device_can_reach_host() {
    local serial="$1"
    [ -n "$serial" ] || return 0
    "${PLATFORM}_can_reach_host" "$serial"
}

#
# Withdraws a device from service, recording when.
# Usage: quarantine_device <serial> <reason>
#
quarantine_device() {
    local serial="$1"
    local reason="$2"
    mkdir -p "$RUNNER_QUARANTINE_DIR"
    date +%s > "$RUNNER_QUARANTINE_DIR/$serial"
    log_info "Withdrawing $serial from this run: $reason. It will be re-checked in ${DEVICE_RECOVERY_WAIT_SECONDS}s."
}

#
# Whether a device is currently withdrawn. Returns 0 (true, skip it) while it is.
#
# A withdrawn device is left alone for DEVICE_RECOVERY_WAIT_SECONDS and then re-probed. These
# outages have been observed to clear on their own, so a device is given back its work rather than
# written off: the point is to stop feeding tests to a device that cannot run them, not to shrink
# the pool permanently. Nothing here restarts or otherwise touches a device.
#
# Usage: device_is_quarantined <serial>
#
device_is_quarantined() {
    local serial="$1"
    local since_file="$RUNNER_QUARANTINE_DIR/$serial"
    [ -f "$since_file" ] || return 1

    local since now
    since="$(cat "$since_file" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ $((now - since)) -lt "$DEVICE_RECOVERY_WAIT_SECONDS" ]; then
        return 0
    fi

    if device_can_reach_host "$serial"; then
        rm -f "$since_file"
        log_info "$serial can reach the host again after $((now - since))s; returning it to service."
        return 1
    fi

    date +%s > "$since_file"
    return 0
}

#
# Watches a device's link to the host for the duration of one test, leaving a marker if it ever
# breaks. Prints the watcher's pid so the caller can stop it.
#
# A check made after a test has failed is not good enough, and the measurements say why. These
# outages are mostly seconds long: of fifteen recorded on one device, most lasted 1 to 4 seconds and
# only one ran to 339. A test waits up to 240 seconds for the app, so by the time it gives up and
# anything asks "can this device reach the host", the answer is usually yes again. The failure looks
# like the app's fault and the outage leaves no trace. Sampling throughout is the only way to catch
# one that has already healed.
#
# Read-only: it pings, nothing else.
#
# Usage: start_device_health_watch <serial> <marker_file>
#
#
# The polling loop of the health watcher. A named function rather than an inline subshell so it can
# be started with the runner's lock descriptors closed, in both of the cases below, without the loop
# being written out twice.
# Usage: device_health_watch_loop <serial> <marker_file>
#
device_health_watch_loop() {
    local serial="$1"
    local marker_file="$2"
    while true; do
        if ! device_can_reach_host "$serial"; then
            date -Is > "$marker_file"
        fi
        sleep "$DEVICE_HEALTH_SAMPLE_SECONDS"
    done
}

start_device_health_watch() {
    local serial="$1"
    local marker_file="$2"

    rm -f "$marker_file"
    if [ -z "$serial" ]; then
        return 0
    fi

    # Started with the runner's lock descriptors closed, for the watcher AND for the adb and sleep
    # processes it spawns.
    #
    # A background process inherits the parent's open file descriptions, flocks included, and an
    # flock lives as long as ANY descriptor referring to that description. The watcher used to
    # inherit the device lock taken by acquire_device, and so did every `sleep` and `adb` it started.
    # release_device closes the worker's own copy, but an inherited copy in a surviving child keeps
    # the emulator locked with nothing using it, and nothing ever frees it: the next run blocks on
    # that lock indefinitely while the device sits idle. run_test_isolated closes the same
    # descriptors for the test for exactly this reason.
    #
    # The device descriptor is only closed when one is held: `{var}>&-` with an empty var is an
    # ambiguous redirect, which would stop the watcher starting at all.
    if [ -n "$ACQUIRED_FD" ]; then
        device_health_watch_loop "$serial" "$marker_file" >/dev/null 2>&1 {ACQUIRED_FD}>&- &
    else
        device_health_watch_loop "$serial" "$marker_file" >/dev/null 2>&1 &
    fi
    echo $!
}

#
# Stops a health watcher started above.
# Usage: stop_device_health_watch <pid>
#
stop_device_health_watch() {
    local watcher_pid="$1"
    [ -n "$watcher_pid" ] || return 0
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
}

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
                # Withdrawn devices are passed over until they can reach the host again.
                if [ -n "$serial" ] && device_is_quarantined "$serial"; then
                    continue
                fi
                # An empty slot means the caller is not binding tests to devices at all, so there is
                # nothing to lock.
                if [ -z "$serial" ]; then
                    ACQUIRED_DEVICE=""
                    ACQUIRED_FD=""
                    return 0
                fi
                # Nothing else can be holding this device when there is no lock to hold it with:
                # run.sh has already refused to start on more than one device in that case, so this
                # run is the only claimant.
                if [ "$RUNNER_HAS_FLOCK" != "1" ]; then
                    ACQUIRED_DEVICE="$serial"
                    ACQUIRED_FD=""
                    adjust_held 1 >/dev/null
                    return 0
                fi
                exec {fd}<>"$(android_device_lock_path "$serial")"
                if runner_flock -n "$fd"; then
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
    if [ "$RUNNER_HAS_FLOCK" != "1" ]; then
        "${PLATFORM}_export_device" "$serial"
        "$@" || status=$?
        return "$status"
    fi
    exec {fd}<>"$(android_device_lock_path "$serial")"
    # Bounded, because this wait used to have no end. The install and cleanup loops in run.sh call
    # this for EVERY device in turn, before any test runs, so a single device whose lock is never
    # released stalls the entire suite rather than costing it that one device. That is not
    # hypothetical: a suite from another checkout leaked the lock for emulator-5556 through a
    # background process that inherited the descriptor, and every later run on this machine blocked
    # on the install loop for as long as that process lived, while two healthy emulators sat idle.
    #
    # Giving up returns DEVICE_UNAVAILABLE_STATUS so the caller can drop that device and carry on
    # with the rest, which is the honest outcome: a device another suite is holding cannot be
    # installed to or cleaned up anyway.
    if ! runner_flock -w "$DEVICE_SETUP_LOCK_TIMEOUT" "$fd"; then
        exec {fd}>&-
        log_error "$serial is still held by another suite after ${DEVICE_SETUP_LOCK_TIMEOUT}s, so this run cannot use it."
        return "$DEVICE_UNAVAILABLE_STATUS"
    fi
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
    if [ "$RUNNER_HAS_FLOCK" != "1" ]; then
        "$@" || status=$?
        return "$status"
    fi
    exec {fd}<>"$BUILD_LOCK_FILE"
    if ! runner_flock -n "$fd"; then
        log_info "Another suite is building; waiting for it to finish..."
        runner_flock "$fd"
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
    elif [ -n "$ACQUIRED_DEVICE" ]; then
        # Claimed without a descriptor, which is what happens where there is no flock to hold one.
        # The count still has to come back down: it is compared against the suite's share, so leaving
        # it up makes the suite believe it is already at its limit and wait out the full claim
        # timeout before every test after the first. Keying the release off the descriptor alone did
        # exactly that, and turned a 20 minute iOS run into hours.
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
#
# Puts a test back on the front of the queue, so it is retried rather than lost.
# Usage: queue_push_front <queue_file> <test_path>
#
queue_push_front() {
    local queue_file="$1"
    local test_path="$2"

    eval "exec $QUEUE_LOCK_FD<>\"\$queue_file.lock\""
    runner_flock "$QUEUE_LOCK_FD"

    printf '%s\n' "$test_path" > "$queue_file.next"
    cat "$queue_file" >> "$queue_file.next" 2>/dev/null || true
    mv "$queue_file.next" "$queue_file"

    runner_flock -u "$QUEUE_LOCK_FD"
    eval "exec $QUEUE_LOCK_FD>&-"
}

queue_pop() {
    local queue_file="$1"
    if [ ! -f "$queue_file" ]; then
        return 0
    fi

    eval "exec $QUEUE_LOCK_FD<>\"\$queue_file.lock\""
    runner_flock "$QUEUE_LOCK_FD"

    local first=""
    if [ -s "$queue_file" ]; then
        first="$(head -1 "$queue_file")"
        tail -n +2 "$queue_file" > "$queue_file.next"
        mv "$queue_file.next" "$queue_file"
    fi

    runner_flock -u "$QUEUE_LOCK_FD"
    eval "exec $QUEUE_LOCK_FD>&-"

    if [ -n "$first" ]; then
        printf '%s\n' "$first"
    fi
    return 0
}

#
# Returns 0 when a test's own directory name is selected by the given filter, so a single test can
# be iterated on without the full build-install-every-test cycle. An empty filter selects every test.
#
# A filter of only digits selects by test number, matching the number in front of the directory name
# exactly: `2` runs 2-create-database and not 12-edit-api-key, 22-edit-database-origin or any of the
# other dozen-odd directories a plain substring match would drag in. Numbers are not unique here (9
# and 17 are each used twice), so a numeric filter can legitimately select more than one test.
#
# Any other filter is a case-insensitive substring of the directory name, so `stale-recent`,
# `29-stale-recent-database` and `Stale` all select the same test.
# Usage: test_matches_filter <test_name> <filter>
#
test_matches_filter() {
    local test_name="$1"
    local filter="$2"

    if [ -z "$filter" ]; then
        return 0
    fi

    case "$filter" in
        *[!0-9]*) ;;
        *)
            # Numeric filter: compare against the leading number only.
            local number="${test_name%%-*}"
            case "$number" in
                ""|*[!0-9]*) return 1 ;;
            esac
            # 10# so a leading zero is not read as octal.
            [ "$((10#$number))" -eq "$((10#$filter))" ]
            return
            ;;
    esac

    # Lowercased with tr rather than ${var,,}, which needs bash 4 and so is not available under the
    # bash macOS ships for the iOS runs.
    local lower_name lower_filter
    lower_name="$(printf '%s' "$test_name" | tr '[:upper:]' '[:lower:]')"
    lower_filter="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"
    case "$lower_name" in
        *"$lower_filter"*) return 0 ;;
    esac
    return 1
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
        run_test_with_timeout "$PER_TEST_TIMEOUT" bash "$test_path" 2>&1 | tee "$log_file"
        status="${PIPESTATUS[0]}"
    else
        run_test_with_timeout "$PER_TEST_TIMEOUT" bash "$test_path" > "$log_file" 2>&1
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
# ambiguous redirect, which would stop the test running at all.
# Usage: run_test_isolated <test_path> <log_file> <duration_file>
#
run_test_isolated() {
    if [ -n "$ACQUIRED_FD" ]; then
        run_test "$1" "$2" "$3" {ACQUIRED_FD}>&-
        return $?
    fi
    run_test "$1" "$2" "$3"
}

#
# One worker: loops popping tests until the queue is empty, taking an emulator for each test and
# handing it straight back afterwards. There is a worker per emulator, so a suite on its own fills
# every one; when suites compete, acquire_device holds each to its fair share.
#
# Each test's verdict is written to its own file in the results directory, so concurrent workers
# never interleave a shared results file.
# Usage: run_worker <queue_file> <results_dir>
#
run_worker() {
    local queue_file="$1"
    local results_dir="$2"

    while true; do
        local test_path
        test_path="$(queue_pop "$queue_file")"
        if [ -z "$test_path" ]; then
            break
        fi

        local dir name test_temp_dir log_file duration_file
        dir="$(dirname "$test_path")"
        name="$(basename "$dir")"
        # A directory of this test's own, outside the source tree and shared with nothing. The test
        # inherits it through the exported variables, so everything it and its child processes write
        # (the app log, the bridge pid file, the CLI's temporary files) lands inside it.
        test_temp_dir="$(photosphere_test_temp_dir "$name")"
        photosphere_export_test_temp "$test_temp_dir"
        log_file="$test_temp_dir/test-run.log"
        duration_file="$test_temp_dir/test-duration.txt"

        # Wait for a free emulator, then bind this test to it. Held only while the test runs.
        if ! acquire_device; then
            printf "${RED}FAIL${NC}  %-32s  no emulator came free within %ss\n" "$name" "$DEVICE_CLAIM_TIMEOUT"
            # No log: the test never ran. The summary prints a dash for it.
            echo "fail $name 0 -" > "$results_dir/$name.result"
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

        # Watch the link to the device for as long as the test runs, so an outage that heals before
        # the test finishes still leaves evidence.
        local health_marker health_watcher
        health_marker="$results_dir/.unreachable-$name"
        health_watcher="$(start_device_health_watch "$ACQUIRED_DEVICE" "$health_marker")"

        local status=0
        run_test_isolated "$test_path" "$log_file" "$duration_file" || status=$?

        # A test that failed on a device which can no longer reach the host tells us nothing about
        # the test: the app cannot talk to the control bridge without the host, so it was never
        # given a chance to run. Recording that as a failure would blame the code for the network,
        # so the result is discarded and the test goes back on the queue for a healthy device.
        #
        # The device check runs only when the test failed, so a passing test is never second-guessed,
        # and the discard needs the device to be provably unreachable now. A test that failed for its
        # own reasons on a healthy device is recorded as a failure exactly as before.
        stop_device_health_watch "$health_watcher"

        # Take this test's data off the device before letting go of it, so the emulator is not left
        # carrying every database, photo and thumbnail that every test before it created. Runs for
        # every test whatever its result, and before the requeue path below, so a discarded attempt
        # cleans up after itself too.
        if [ -n "$ACQUIRED_DEVICE" ]; then
            "${PLATFORM}_clean_after_test"
        fi

        # Discard when the device lost the host at any point during the test, or has lost it now.
        # The marker covers an outage that has already healed, which is the common case; the live
        # check covers one that is still going.
        if [ "$status" -ne 0 ] && [ -n "$ACQUIRED_DEVICE" ] \
            && { [ -f "$health_marker" ] || ! device_can_reach_host "$ACQUIRED_DEVICE"; }; then
            local requeue_file requeues
            requeue_file="$results_dir/.requeues-$name"
            requeues="$(cat "$requeue_file" 2>/dev/null || echo 0)"

            if [ "$requeues" -lt "$MAX_DEVICE_REQUEUES_PER_TEST" ]; then
                echo $((requeues + 1)) > "$requeue_file"
                local why="it could not reach $DEVICE_HEALTH_HOST when $name failed on it"
                if [ -f "$health_marker" ]; then
                    why="it lost $DEVICE_HEALTH_HOST while $name was running (first seen $(cat "$health_marker" 2>/dev/null))"
                fi
                quarantine_device "$ACQUIRED_DEVICE" "$why"
                printf "${BLUE}RETRY${NC} %-32s  discarded: %s could not reach the host (attempt %s of %s)\n" \
                    "$name" "$ACQUIRED_DEVICE" "$((requeues + 1))" "$MAX_DEVICE_REQUEUES_PER_TEST"
                queue_push_front "$queue_file" "$test_path"
                release_device
                continue
            fi

            # Out of retries. Recorded as a real failure below, with the reason made plain, because a
            # test that could never be run is something to report rather than to keep hiding.
            log_error "$name has been discarded $requeues time(s) for unreachable devices; recording it as a failure."
        fi

        release_device

        local duration
        duration="$(cat "$duration_file" 2>/dev/null || echo 0)"
        # The log path goes in the result file because it can no longer be reconstructed from the
        # test's name: every test gets a uniquely named directory of its own, which is the point.
        if [ "$status" -eq "$TEST_SKIPPED_EXIT_CODE" ]; then
            # Recorded separately from a pass so a test that ran nothing is never counted as coverage.
            printf "${BLUE}SKIP${NC}  %-32s  %ss  (log: %s)\n" "$name" "$duration" "$log_file"
            echo "skip $name $duration $log_file" > "$results_dir/$name.result"
        elif [ "$status" -eq 0 ]; then
            printf "${GREEN}PASS${NC}  %-32s  %ss\n" "$name" "$duration"
            echo "pass $name $duration $log_file" > "$results_dir/$name.result"
        elif test_timed_out "$status"; then
            # Called out separately from a failure. A failure says the code is wrong; a timeout says
            # the test stopped making progress and never got as far as deciding, which is a different
            # thing to go and look at. The two are indistinguishable in a summary otherwise.
            report_test_timeout "$name" "$PER_TEST_TIMEOUT" "$log_file"
            echo "fail $name $duration $log_file" > "$results_dir/$name.result"
        else
            printf "${RED}FAIL${NC}  %-32s  %ss  (log: %s)\n" "$name" "$duration" "$log_file"
            echo "fail $name $duration $log_file" > "$results_dir/$name.result"
        fi
    done
}

#
# Runs every given test across the device slots in RUNNER_SLOTS, one worker per slot. Returns
# non-zero if any test failed. The queue lives in a temp directory that is removed when the pool
# finishes.
# Usage: run_pool <results_dir> <test_path...>
#
run_pool() {
    local results_dir="$1"
    shift

    # Per-run, so every run starts by judging the devices fresh rather than inheriting a verdict.
    RUNNER_QUARANTINE_DIR="$results_dir/.withdrawn-devices"
    mkdir -p "$RUNNER_QUARANTINE_DIR"

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

    local work_dir queue_file
    work_dir="$(mktemp -d)"
    queue_file="$work_dir/queue"
    queue_init "$queue_file" "$@"
    mkdir -p "$results_dir"

    log_info "Using up to ${#RUNNER_SLOTS[@]} emulator(s); currently sharing with $(active_suite_count) suite(s), so this one's share is $(suite_share)."

    local pids=()
    local worker
    for worker in $(seq 1 "$workers"); do
        run_worker "$queue_file" "$results_dir" &
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
