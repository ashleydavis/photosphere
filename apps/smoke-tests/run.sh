#!/usr/bin/env bash
set -euo pipefail

# Discovers and runs the mobile smoke tests (tests/*/test.sh) on the platform given by the
# PLATFORM env var (android or ios). Builds and installs the app once up front, then spreads the
# tests over the available devices. Mirrors apps/desktop/smoke-tests.sh but without an in-app
# control server (the host control bridge handles that, see lib/common.sh).

# Nothing in a test run may read the terminal. This is a non-interactive suite, but the build
# toolchain underneath it (cap sync, Gradle) can try stdin, and a backgrounded job that reads the
# tty is stopped by the kernel with SIGTTIN. That made `bun run test:and &` suspend instead of run,
# so several suites could not be started from one terminal without redirecting stdin by hand.
# Detaching stdin here means backgrounding just works, with no ceremony at the call site.
exec </dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

: "${PLATFORM:?PLATFORM must be set to 'android' or 'ios'}"

# Sourcing common.sh also sources the platform launcher and defines the *_prepare/_build/etc.
# It sources scripts/lib/process-control.sh too, which is where the leak check comes from. Every
# control bridge the tests launch records its process group in this file, and the check at the end
# looks at those groups and nothing else. Exported, because the launches happen in the test.sh child
# processes.
source "$SCRIPT_DIR/lib/common.sh"
export PHOTOSPHERE_LAUNCHED_GROUPS
PHOTOSPHERE_LAUNCHED_GROUPS="$(mktemp "${TMPDIR:-/tmp}/photosphere-mobile-launches-XXXXXX")"

#
# Fails the run when anything this suite launched is still running at the end of it.
#
# It looks only at the process groups this suite's own launches recorded, so the four other suites
# that `bun run test:everything` runs alongside this one cannot be mistaken for its leak.
#
# The second look comes after a pause. A test's cleanup signals its bridge and returns without
# waiting for it, so looking immediately races the kernel finishing it off.
#
check_for_leaked_processes() {
    local leaked
    leaked="$(list_leaked_launches)"
    if [ -z "$leaked" ]; then
        return 0
    fi
    sleep 5
    leaked="$(list_leaked_launches)"
    if [ -z "$leaked" ]; then
        return 0
    fi

    echo ""
    printf "${RED}LEAK: this run left processes it started still running.${NC}\n"
    printf '%s\n' "$leaked" | while IFS= read -r leaked_line; do
        echo "  $leaked_line"
    done
    echo ""
    echo "Stop them before running again; they hold memory until something does."
    return 1
}

# The work queue and worker pool that spread the tests over the available devices. It allocates a
# uniquely named directory for each test as it dispatches it, so nothing needs to be scoped per run
# here: no two tests share a directory whether they are in the same run or not.
source "$SCRIPT_DIR/lib/runner.sh"

discover_tests() {
    find "$SCRIPT_DIR/tests" -maxdepth 2 -name "test.sh" 2>/dev/null | sort -V
}

#
# Clears the app's data from every device the run used. Runs from the EXIT trap, so it must not
# leave ANDROID_SERIAL pointing at whichever device happened to be last.
#
cleanup_all_devices() {
    local slot
    for slot in "${RUNNER_SLOTS[@]}"; do
        # A device this run can no longer claim is skipped rather than waited on. This runs from the
        # EXIT trap, so blocking here would leave the run unable to finish at all.
        with_device "$slot" "${PLATFORM}_cleanup" || true
    done
}

main() {
    # Optional first argument narrows the run to one test, by number ("29") or by name
    # ("29-stale-recent-database" or "stale-recent"), so it can be iterated on without the full
    # build-install-every-test cycle. See test_matches_filter. An absent argument runs every test.
    local filter="${1:-}"

    # Selected up front, before the emulator check and the build, so a filter that matches nothing
    # fails in a second rather than after a full build-and-install.
    local tests=()
    local test_path test_name
    while IFS= read -r test_path; do
        test_name="$(basename "$(dirname "$test_path")")"
        if test_matches_filter "$test_name" "$filter"; then
            tests+=("$test_path")
        fi
    done < <(discover_tests)

    if [ ${#tests[@]} -eq 0 ]; then
        if [ -n "$filter" ]; then
            # A filter that matches nothing is an error, not a silent zero-test pass. The available
            # tests are listed because the usual cause is a mistyped name or a number that moved.
            log_error "No tests matched: $filter"
            echo "Available tests:"
            discover_tests | while IFS= read -r test_path; do
                echo "  $(basename "$(dirname "$test_path")")"
            done
            exit 1
        fi
        echo "No tests found in tests/"
        exit 0
    fi

    if [ -n "$filter" ]; then
        log_info "Selected ${#tests[@]} test(s) matching '$filter':"
        for test_path in "${tests[@]}"; do
            echo "  $(basename "$(dirname "$test_path")")"
        done
    fi

    # Android: fail immediately unless the emulator is already started and on the LAN bridge. This
    # never boots or changes the emulator; readiness is set up by hand. The single-run lock is taken
    # outside this script by android-lock.sh, which `test:and` wraps this run in.
    if [ "$PLATFORM" = "android" ]; then
        android_require_ready
    fi

    "${PLATFORM}_prepare"

    # One suite builds at a time: concurrent builds out of one checkout corrupt each other.
    with_build_lock "${PLATFORM}_build"

    # Every ready device is a candidate. Nothing is reserved here: a worker takes an emulator for one
    # test and hands it back, so other suites running at the same time get their turn too.
    RUNNER_SLOTS=()
    while IFS= read -r slot; do
        RUNNER_SLOTS+=("$slot")
    done < <("${PLATFORM}_device_slots")

    if [ ${#RUNNER_SLOTS[@]} -eq 0 ]; then
        log_error "No usable device found for $PLATFORM."
        exit 1
    fi

    # Without flock there is nothing keeping two workers off the same queue entry or the same device,
    # so more than one device would quietly run tests twice and skip others. One device means one
    # worker, which needs no locking at all, and that is the case this platform is expected to be in
    # (macOS has no flock, and an iOS run has a single simulator). Anything else has to stop here
    # rather than produce a run whose results cannot be trusted.
    if [ "$RUNNER_HAS_FLOCK" != "1" ] && [ ${#RUNNER_SLOTS[@]} -gt 1 ]; then
        log_error "Found ${#RUNNER_SLOTS[@]} devices but this platform has no flock, so the work queue and"
        log_error "device claims cannot be made safe. Run on one device, or on a platform with flock."
        exit 1
    fi

    log_info "Running on ${#RUNNER_SLOTS[@]} device(s): ${RUNNER_SLOTS[*]}"

    # Put this run's build onto every device it can actually claim. A device another suite is holding
    # is dropped from the run rather than waited on forever: this loop happens before any test starts,
    # so one stuck lock used to stall the whole suite while the remaining emulators sat idle. The
    # drop is reported, never silent, because a run on fewer devices is a smaller run.
    #
    # *_ensure_apk rather than *_install, so a device that already carries this exact build is left
    # alone. The check is the APK's own checksum, so this still guarantees what the unconditional
    # install guaranteed: no test ever runs against another worktree's build or a stale one. What it
    # stops is reinstalling an unchanged 117MB APK onto all five emulators at the top of every run,
    # which is where the emulators' memory was going. Each emulator kept roughly 40MB of host memory
    # per run and never gave it back, so a repeated run walked them into their 8G limit and killed
    # them with SIGSEGV after a couple of hours. A single build is installed once and then reused.
    local slot
    local usable_slots=()
    local install_status
    for slot in "${RUNNER_SLOTS[@]}"; do
        install_status=0
        with_device "$slot" "${PLATFORM}_ensure_apk" || install_status=$?
        if [ "$install_status" -eq 0 ]; then
            usable_slots+=("$slot")
        elif [ "$install_status" -ne "$DEVICE_UNAVAILABLE_STATUS" ]; then
            log_error "Installing the app on $slot failed (exit $install_status)."
            exit 1
        fi
    done

    if [ ${#usable_slots[@]} -eq 0 ]; then
        log_error "Every device is held by another suite, so this run has nothing to test on."
        exit 1
    fi

    if [ ${#usable_slots[@]} -ne ${#RUNNER_SLOTS[@]} ]; then
        log_error "Running on ${#usable_slots[@]} of ${#RUNNER_SLOTS[@]} device(s): ${usable_slots[*]}. The rest are held by another suite."
    fi
    RUNNER_SLOTS=("${usable_slots[@]}")

    # Clear the app's data from every device however the run ends, so the databases the tests seed
    # and import into do not pile up until a device runs out of storage. Deregistering here too, so
    # an interrupted run does not leave a registration behind shrinking the other suites' shares.
    trap 'cleanup_all_devices; deregister_suite' EXIT

    local results_dir
    results_dir="$(mktemp -d)"
    run_pool "$results_dir" "${tests[@]}" || true

    local pass=0
    local fail=0
    # Skipped tests are counted apart from passes. A gated test (no LAN bridge, or an Android-only
    # test dispatched on iOS) runs none of its body, and counting it in "All N tests passed" reported
    # coverage that had not happened. Naming them in the summary is what makes that visible.
    local skip=0
    local skipped_names=()
    local failed_names=()
    local failed_logs=()
    local result_file verdict name log_path
    for result_file in "$results_dir"/*.result; do
        [ -e "$result_file" ] || continue
        verdict="$(awk '{ print $1 }' "$result_file")"
        name="$(awk '{ print $2 }' "$result_file")"
        log_path="$(awk '{ print $4 }' "$result_file")"
        if [ "$verdict" = "pass" ]; then
            pass=$((pass + 1))
        elif [ "$verdict" = "skip" ]; then
            skip=$((skip + 1))
            skipped_names+=("$name")
        else
            fail=$((fail + 1))
            failed_names+=("$name")
            failed_logs+=("$log_path")
        fi
    done
    rm -rf "$results_dir"

    echo ""
    # Printed before the verdict, and named one per line, so a run that skipped something can never
    # be read as a run that covered everything.
    if [ "$skip" -gt 0 ]; then
        printf "${BLUE}%d test(s) skipped, so they proved nothing this run:${NC}\n" "$skip"
        local skipped_index=0
        while [ "$skipped_index" -lt "${#skipped_names[@]}" ]; do
            printf "${BLUE}  %s${NC}\n" "${skipped_names[$skipped_index]}"
            skipped_index=$((skipped_index + 1))
        done
        echo ""
    fi
    if [ "$fail" -eq 0 ]; then
        printf "${GREEN}All %d tests passed${NC}\n" "$pass"
    else
        # Workers interleave their output, so each failure's log path is printed here rather than
        # leaving it to be hunted for in the scrollback.
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$((pass + fail))"
        # The path comes from the result file: each test has a uniquely named directory of its own,
        # so it cannot be rebuilt from the test's name.
        local failed_index=0
        while [ "$failed_index" -lt "${#failed_names[@]}" ]; do
            printf "${RED}  %s${NC}  (log: %s)\n" "${failed_names[$failed_index]}" "${failed_logs[$failed_index]}"
            failed_index=$((failed_index + 1))
        done
    fi
    # A run that leaves control bridges behind has failed even when every test passed.
    local leaked=0
    check_for_leaked_processes || leaked=1
    rm -f "$PHOTOSPHERE_LAUNCHED_GROUPS"

    return $(((fail > 0 || leaked > 0) ? 1 : 0))
}

main "$@"
