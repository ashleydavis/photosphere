#!/usr/bin/env bash

# With the setting system, a change of the system's appearance reaches the page while the app runs. It changes the system's
# appearance, which on a desktop is the developer's own screen, so it runs only in the workflow or when named.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

#
# Puts the system's appearance back, then stops the app.
#
cleanup_theme_and_apps() {
    if [ -f "$TMP_DIR/system-appearance.txt" ]; then
        photosphere_platform_restore_system_theme "$TMP_DIR" || true
    fi
    cleanup_apps "$TMP_DIR"
}
trap cleanup_theme_and_apps EXIT

photosphere_platform_changes_appearance || exit 77

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
expected="$(photosphere_platform_system_theme "$TMP_DIR")" || fail "the operating system's theme could not be read"
wait_for_attribute "$APP_PORT" "class" "$expected" 10

if [ "$expected" = "dark" ]; then
    other="light"
else
    other="dark"
fi
photosphere_platform_set_system_theme "$TMP_DIR" "$other" || exit 1
wait_for_attribute "$APP_PORT" "class" "$other" 10
log_success "The page followed a change of the system's theme while the app ran"

photosphere_platform_restore_system_theme "$TMP_DIR" || exit 1
wait_for_attribute "$APP_PORT" "class" "$expected" 10
check_no_errors "$TMP_DIR" || exit 1
