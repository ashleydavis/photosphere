#!/usr/bin/env bash

# The Quit item ends the app, and everything it started, even with tasks running.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

choose_menu_item start-long
choose_menu_item start-many
wait_for_text output "long task step 2"
choose_menu_item quit
if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 30; then
    fail "the app and its processes were still running 30 seconds after Quit was chosen"
fi
