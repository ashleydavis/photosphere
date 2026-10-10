#!/bin/bash

# Adds a database entry, edits its origin and saves. On a desktop the saved origin is read back from the database's own
# .db/config.json. On a phone the database lives in the app's sandbox, so only the UI flow is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 22 "edit-database-origin"

NEW_ORIGIN="s3:my-bucket:/origin-database"

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

log_info "Pre-creating database with the CLI..."
create_database "$TMP_DIR/test-db"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db" || exit 1
        ;;
esac

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Register the database as an entry.
case "$PLATFORM" in
    android|ios)
        send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

# Open the Edit dialog from the row's edit button.
send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"
case "$PLATFORM" in
    android|ios)
        # Confirming the Add Database dialog opens the database, which re-renders the card list after "Database entry added" is
        # logged. Wait for that to settle before opening the menu, or it tears the menu down before the action can be clicked.
        wait_for_value "$APP_PORT" database-photo-count "photos"
        wait_for_log "$TMP_DIR" "Database opened"
        wait_for_log "$TMP_DIR" "Databases page loaded"
        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"edit-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit database dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$NEW_ORIGIN" '{dataId: "database-origin-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"save-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry updated"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        # The origin is persisted to .db/config.json, the canonical source of truth.
        CONFIG_PATH="$TMP_DIR/test-db/.db/config.json"
        if [ ! -f "$CONFIG_PATH" ]; then
            log_error "Expected database config at $CONFIG_PATH but file does not exist"
            exit 1
        fi
        SAVED_ORIGIN="$(jq -j '.origin' "$CONFIG_PATH")"
        if [ "$SAVED_ORIGIN" != "$NEW_ORIGIN" ]; then
            log_error ".db/config.json origin mismatch"
            log_error "Expected: $NEW_ORIGIN"
            log_error "Actual:   $SAVED_ORIGIN"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 22 passed: edit-database-origin"
