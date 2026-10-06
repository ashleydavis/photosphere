#!/usr/bin/env bash

# A keep-alive task goes on running when the window is closed (on a desktop) or the app goes to the background (on a phone). It
# counts in a file in the data directory, which is what the scenario watches, because the page is not there to ask. On a desktop
# the app then ends by itself when the task does. A phone's app stays, so there the scenario checks the app's process is still
# running instead.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click start-keep-alive
before="$(wait_for_data_file_number keep-alive.txt 2)"
ziggy_platform_leave_app "$ZIGGY_TEST_DIR" || fail "could not take the app out of sight"
sleep 3
after="$(data_file_number keep-alive.txt)"
if [ "$after" -le "$before" ]; then
    fail "the keep-alive task stopped counting when the app left the foreground: $before then $after"
fi
if ! ziggy_platform_process_alive "$ZIGGY_TEST_DIR"; then
    fail "the app's process ended while a keep-alive task was running"
fi

case "$ZIGGY_SMOKE_PLATFORM" in
    android)
        ziggy_platform_keep_alive_service_running || fail "the foreground service is not running"
        ;;
    linux|windows|macos)
        # The task runs for fifteen seconds and the app ends with it.
        if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 60; then
            fail "the app was still running 60 seconds after its keep-alive task should have ended"
        fi
        ;;
esac
