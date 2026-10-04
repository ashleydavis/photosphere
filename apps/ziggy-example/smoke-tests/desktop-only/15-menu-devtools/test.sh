#!/usr/bin/env bash

# The Toggle Developer Tools item opens the developer tools, and choosing it again closes them. How a script sees them differs between
# platforms, so each platform's library says (ziggy_platform_devtools_visible).

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

normal="$(viewport_size)"

wait_for_devtools() {
    local waited=0
    while ! ziggy_platform_devtools_visible "$ZIGGY_TEST_DIR" "$normal"; do
        if [ "$waited" -ge 30 ]; then
            fail "$1"
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

wait_for_devtools_gone() {
    local waited=0
    while ziggy_platform_devtools_visible "$ZIGGY_TEST_DIR" "$normal"; do
        if [ "$waited" -ge 30 ]; then
            fail "$1"
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

if ziggy_platform_devtools_visible "$ZIGGY_TEST_DIR" "$normal"; then
    fail "the developer tools were showing before the menu item was chosen"
fi
choose_menu_item toggle-devtools
wait_for_devtools "the developer tools never opened"
choose_menu_item toggle-devtools
wait_for_devtools_gone "the developer tools never closed"
