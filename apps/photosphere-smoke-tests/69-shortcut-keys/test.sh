#!/usr/bin/env bash

# The File menu's shortcuts work as a user presses them: Ctrl+N opens the Create Database dialog, and Ctrl+O opens the Open Database
# dialog. Ctrl+N is the File menu's New Database item, and Ctrl+O is the open-database action. The app is restarted between them so the
# second dialog opens on a page with none open.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 69 "shortcut-keys"

case "$PLATFORM" in
    android|ios)
        log_info "SKIP: a mobile has no shortcuts. Skipping."
        exit 77
        ;;
esac

trap 'cleanup_apps "$TMP_DIR"' EXIT
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
press_key "$APP_PORT" CmdOrCtrl+N || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened" || exit 1
check_no_errors "$TMP_DIR" || exit 1

stop_app "$APP_PORT" "$TMP_DIR"
reset_log_cursor "$TMP_DIR"
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
press_key "$APP_PORT" CmdOrCtrl+O || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened" || exit 1
check_no_errors "$TMP_DIR" || exit 1

log_success "Test 69 passed: shortcut-keys"
