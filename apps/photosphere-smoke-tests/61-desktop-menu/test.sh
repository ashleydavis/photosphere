#!/bin/bash

# A desktop menu action reaches the page: a menu action that navigates changes the route the page shows.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 61 "desktop-menu"

case "$PLATFORM" in
    android|ios)
        log_info "SKIP: a phone has no desktop menu. Skipping."
        exit 77
        ;;
esac

trap 'cleanup_apps "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# A navigating menu action changes the route the page shows.
send_command "$APP_PORT" menu '{"action":"navigate:/about"}' || exit 1
wait_for_value "$APP_PORT" "about-version" "Version" || exit 1
log_success "A menu action navigated the page to the about page"

check_no_errors "$TMP_DIR" || exit 1

log_success "Test 61 passed: desktop-menu"
