#!/bin/bash

# Adds a database entry on the Databases page, then checks the entry reached storage. On a desktop the database is created with the CLI
# and the entry points at its path. On a phone an empty database is copied into the app's sandbox and the entry's path is its
# sandbox-relative name. Adding auto-opens the database, so it must be present to load cleanly.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 6 "add-database-entry"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # The name carries no spaces because the assertion below reads the row back through the control connection.
        ENTRY_NAME="my-test-db"
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        ENTRY_NAME="My Test DB"
        DATABASE_PATH="$TMP_DIR/test-db"
        ;;
esac

log_info "Pre-creating database with the CLI..."
create_database "$TMP_DIR/test-db"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"
        ;;
esac

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

case "$PLATFORM" in
    android|ios)
        # The Add button is in the page's actions menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$ENTRY_NAME" '{dataId: "database-name-input", text: $text}')" || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

# The log line alone proves nothing: it is written straight after awaiting the add, so an entry that never reaches storage leaves it
# intact. Reading the entry back is the assertion that it was added.
case "$PLATFORM" in
    android|ios)
        # The databases page renders one row per configured entry.
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_value "$APP_PORT" "database-row-name-$ENTRY_NAME" "$ENTRY_NAME"
        ;;
    *)
        DATABASES_TOML="$TMP_DIR/config/databases.toml"
        if [ ! -f "$DATABASES_TOML" ]; then
            log_error "The app reported 'Database entry added' but wrote no $DATABASES_TOML"
            exit 1
        fi
        if ! grep -q 'My Test DB' "$DATABASES_TOML"; then
            log_error "The app reported 'Database entry added' but $DATABASES_TOML has no entry named 'My Test DB'"
            cat "$DATABASES_TOML"
            exit 1
        fi
        log_success "The database entry is in databases.toml"
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
