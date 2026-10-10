#!/bin/bash

# Opens the sidebar and removes a recent database. On a desktop two databases are created with the CLI and databases.toml is seeded
# with both as entries and as recents, and the file is checked afterwards: the recent name is gone and both entries remain. On a phone
# the recent list lives on the device, so one database is copied into the sandbox, configured and opened, and only the removal is covered.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 16 "remove-recent-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        create_database "$TMP_DIR/test-db"
        ;;
    *)
        log_info "Pre-creating two databases with the CLI..."
        create_database "$TMP_DIR/test-db-a"
        create_database "$TMP_DIR/test-db-b"

        log_info "Writing databases.toml seeded with two entries and both in recent_database_names..."
        mkdir -p "$TMP_DIR/config"
        cat > "$TMP_DIR/config/databases.toml" <<TOML
recent_database_names = ["test-db-a", "test-db-b"]

[[databases]]
name = "test-db-a"
description = ""
path = "$TMP_DIR/test-db-a"

[[databases]]
name = "test-db-b"
description = ""
path = "$TMP_DIR/test-db-b"
TOML
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db"
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        # Recents are stored as names and resolved against the configured databases, so a recent with no matching configured entry is
        # dropped on read and never renders. Seed the entry as well as the recent.
        "${PLATFORM}_seed_databases_config" "[{\"name\":\"test-db\",\"path\":\"$DATABASE_PATH\"}]" '["test-db"]' || exit 1
        # Open the database so the sidebar re-reads the recent list, which it refreshes on the database-opened event.
        send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DATABASE_PATH" '{path: $path}')" || exit 1
        wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
        ;;
esac

log_info "Opening the left sidebar..."
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1

# Wait for the drawer to mount and the recent databases list to render. Waiting for the row about to be acted on is both quicker than a
# fixed pause and stricter.
case "$PLATFORM" in
    android|ios)
        wait_for_value "$APP_PORT" "recent-database-name-0" "test-db"
        ;;
    *)
        wait_for_value "$APP_PORT" "recent-database-name-0" "test-db-a"
        ;;
esac

log_info "Clicking the trash icon for the first recent database..."
send_command "$APP_PORT" click '{"dataId":"remove-recent-database-button-0"}' || exit 1
wait_for_log "$TMP_DIR" "Recent database removed"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        TOML_FILE="$TMP_DIR/config/databases.toml"

        if grep -q "test-db-a" <(grep "^recent_database_names" "$TOML_FILE"); then
            log_error "test-db-a still present in recent_database_names"
            cat "$TOML_FILE"
            exit 1
        fi

        if ! grep -q "test-db-b" <(grep "^recent_database_names" "$TOML_FILE"); then
            log_error "test-db-b unexpectedly missing from recent_database_names"
            cat "$TOML_FILE"
            exit 1
        fi

        # Both [[databases]] entries must still be present.
        db_count=$(grep -c "^\[\[databases\]\]" "$TOML_FILE")
        if [ "$db_count" -ne 2 ]; then
            log_error "Expected 2 [[databases]] entries, found $db_count"
            cat "$TOML_FILE"
            exit 1
        fi

        if ! grep -q "path = \"$TMP_DIR/test-db-a\"" "$TOML_FILE"; then
            log_error "test-db-a database entry was unexpectedly removed"
            cat "$TOML_FILE"
            exit 1
        fi
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 16 passed: remove-recent-database"
