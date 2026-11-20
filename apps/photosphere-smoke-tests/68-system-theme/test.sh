#!/usr/bin/env bash

# With the setting system, the app's theme is the operating system's theme.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

trap 'cleanup_apps "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
expected="$(photosphere_platform_system_theme "$TMP_DIR")" || fail "the operating system's theme could not be read"
wait_for_attribute "$APP_PORT" "class" "$expected" 10
check_no_errors "$TMP_DIR" || exit 1
