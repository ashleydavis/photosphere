#!/usr/bin/env bash

# A keep-alive task goes on running when a phone's app goes to the background. It counts in a file in the data directory, which is
# what the scenario watches, because the page is not there to ask. On Android the foreground service is running too. A desktop has no
# background: closing the window quits the app, keep-alive task or not, so there the scenario checks the app ends and the task with it.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click start-keep-alive
before="$(wait_for_data_file_number keep-alive.txt 2)"
ziggy_platform_leave_app "$ZIGGY_TEST_DIR" || fail "could not take the app out of sight"

case "$ZIGGY_SMOKE_PLATFORM" in
    linux|windows|macos)
        if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 10; then
            fail "the app was still running 10 seconds after its window was closed with a keep-alive task running"
        fi
        ;;
    *)
        sleep 3
        after="$(data_file_number keep-alive.txt)"
        if [ "$after" -le "$before" ]; then
            fail "the keep-alive task stopped counting when the app left the foreground: $before then $after"
        fi
        if ! ziggy_platform_process_alive "$ZIGGY_TEST_DIR"; then
            fail "the app's process ended while a keep-alive task was running"
        fi
        if [ "$ZIGGY_SMOKE_PLATFORM" = "android" ]; then
            ziggy_platform_keep_alive_service_running || fail "the foreground service is not running"
        fi
        ;;
esac
