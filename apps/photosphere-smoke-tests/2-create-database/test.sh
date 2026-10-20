#!/bin/bash

# Drives the new-database flow from the left sidebar and creates a new empty database. On a desktop the path is absolute and the database
# is checked on disk. On a phone the path is relative to the app's storage sandbox, the only place the app may write.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 2 "create-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_reset_app_state" || exit 1
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        ;;
    *)
        DATABASE_PATH="$TMP_DIR/test-db"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        # Create requires an empty directory.
        "${PLATFORM}_reset_path" "test-db" || exit 1
        ;;
esac

click_sidebar_item "$APP_PORT" new-database || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Database created"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        if [ ! -d "$TMP_DIR/test-db/.db" ]; then
            log_error "Expected $TMP_DIR/test-db/.db directory to exist"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 2 passed: create-database"
