#!/usr/bin/env bash

# Closing the window with only a normal background task running ends the app, and the task with it.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

click start-background-normal
wait_for_data_file_number normal.txt 2 > /dev/null
ziggy_platform_leave_app "$ZIGGY_TEST_DIR" || fail "could not close the window"
if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 10; then
    fail "the app was still running 10 seconds after its window was closed with only a normal task running"
fi
