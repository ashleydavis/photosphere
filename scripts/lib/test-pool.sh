#!/usr/bin/env bash

# The rolling pool the shell smoke-test runners schedule their tests with, in one place.
#
# Source this from a runner:
#   source "<repo>/scripts/lib/test-pool.sh"
#
# It defines functions only and does nothing when sourced.
#
# A rolling pool rather than batches. Batches waited for every test in one before starting any of the
# next, so a batch cost as much as its slowest member and the machine sat idle for the difference: in
# a measured CLI run the batch maxima summed to 283s against 182s of work per lane, which is 101s
# spent doing nothing. Here a slot is refilled the moment the test in it finishes.
#
# Written for the bash macOS ships, which is 3.2: no associative arrays and no `wait -n`. The slots
# are three indexed arrays rather than one array of records, and they are polled with `kill -0`
# rather than waited on. `wait` is still what reads the exit status, and it returns immediately for a
# job already known to have finished.

# Seconds between looks at the running tests. A tenth of a second, because this is what decides how
# long a freed slot sits empty before the next test starts, and the poll itself is a `kill -0` per
# running test.
TEST_POOL_POLL_INTERVAL=0.1

# Where the start function leaves the pid of the job it started, and whatever the report function
# needs to find that job's output afterwards (the directory the test was told to write to). Globals
# rather than a value printed on stdout, and this is load-bearing: a job started inside a command
# substitution belongs to that subshell, so this shell could neither `wait` for it nor read its exit
# status.
TEST_POOL_JOB_PID=""
TEST_POOL_JOB_CONTEXT=""

#
# Runs a list of tests, keeping at most <n> of them going at once.
#
# start_fn is called as `start_fn <test_sh>` and must start exactly one background job, leaving its
# pid in TEST_POOL_JOB_PID and anything the reporter needs in TEST_POOL_JOB_CONTEXT.
#
# report_fn is called as `report_fn <status> <test_sh> <context>` once a slot's job has finished,
# with the status `wait` returned for it. Counting outcomes is the reporter's job, not the pool's:
# the two suites that use this disagree about what outcomes exist (the CLI suite has skips, the
# desktop suite does not), so the pool stays out of it.
#
# Results are reported as tests finish rather than in test order, which is what the batch runner this
# replaced already did within a batch.
# Usage: run_test_pool <n> <start_fn> <report_fn> <test...>
#
run_test_pool() {
    local pool_width="$1"
    local start_fn="$2"
    local report_fn="$3"
    shift 3
    local tests=("$@")
    local total="${#tests[@]}"
    local next=0
    local in_flight=0

    # Slot i holds the pid of the test running in it, the test it is running and the context its
    # start function handed back. An empty pid means the slot is free.
    local test_pool_pids=()
    local test_pool_tests=()
    local test_pool_contexts=()
    local slot=0
    while ((slot < pool_width)); do
        test_pool_pids[slot]=""
        test_pool_tests[slot]=""
        test_pool_contexts[slot]=""
        slot=$((slot + 1))
    done

    while ((next < total || in_flight > 0)); do
        # Fill every free slot before looking at anything, so a test starts the moment there is room
        # for it.
        slot=0
        while ((slot < pool_width && next < total)); do
            if [ -z "${test_pool_pids[slot]}" ]; then
                TEST_POOL_JOB_PID=""
                TEST_POOL_JOB_CONTEXT=""
                "$start_fn" "${tests[next]}"
                test_pool_pids[slot]="$TEST_POOL_JOB_PID"
                test_pool_tests[slot]="${tests[next]}"
                test_pool_contexts[slot]="$TEST_POOL_JOB_CONTEXT"
                in_flight=$((in_flight + 1))
                next=$((next + 1))
            fi
            slot=$((slot + 1))
        done

        sleep "$TEST_POOL_POLL_INTERVAL"

        slot=0
        while ((slot < pool_width)); do
            local slot_pid="${test_pool_pids[slot]}"
            if [ -n "$slot_pid" ] && ! kill -0 "$slot_pid" 2>/dev/null; then
                local slot_status=0
                wait "$slot_pid" || slot_status=$?
                "$report_fn" "$slot_status" "${test_pool_tests[slot]}" "${test_pool_contexts[slot]}"
                test_pool_pids[slot]=""
                test_pool_tests[slot]=""
                test_pool_contexts[slot]=""
                in_flight=$((in_flight - 1))
            fi
            slot=$((slot + 1))
        done
    done
}
