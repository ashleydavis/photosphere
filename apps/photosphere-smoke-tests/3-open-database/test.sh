#!/bin/bash

# Opens a configured database from the open-database dialog and expects the open to complete, then restarts the app and expects the
# same database to open by itself. On a desktop the database is created with the CLI and databases.toml is written beside the app's
# settings, and the database summary is opened from the sidebar and from the navbar's photo count. On a phone the 50-assets fixture is
# copied into the app's sandbox, configured, and the sidebar's recent list is checked to show it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 3 "open-database"

DB_NAME="test-db"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
    *)
        log_info "Pre-creating database with the CLI..."
        create_database "$TMP_DIR/test-db"

        log_info "Writing databases.toml with one entry..."
        mkdir -p "$TMP_DIR/config"
        cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
TOML
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/50-assets" "$DB_NAME" || exit 1
        DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"
        "${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"}]" || exit 1
        ;;
esac

send_command "$APP_PORT" menu '{"action":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

# The app has to say it is opening, and then say it opened. Tapping a database queues a probe task and then a load, and the dialog
# stays open, disables every entry and spins on the one tapped until the open resolves. The pair of log lines is asserted rather than
# the spinner itself: the state clears as soon as the open finishes, so polling the DOM for it is a race a quick open would win.
wait_for_log "$TMP_DIR" "Opening database:"
wait_for_log "$TMP_DIR" "Database opened"

case "$PLATFORM" in
    android|ios)
        # The sidebar refreshes its recent list only on the database-opened callback, which the real open flow above drives. Without
        # the callback the element would stay empty.
        send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
        wait_for_value "$APP_PORT" "recent-database-name-0" "$DB_NAME"
        ;;
    *)
        # The database was just created by the CLI and holds all its files, so its mode is full.
        log_info "Opening the left sidebar..."
        send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
        wait_for_value "$APP_PORT" "sidebar-database-summary" "Database Info"

        send_command "$APP_PORT" click '{"dataId":"sidebar-database-summary"}' || exit 1
        wait_for_log "$TMP_DIR" "Database summary loaded:"
        wait_for_value "$APP_PORT" database-mode "full"

        # The same summary is a click away from the navbar's photo count, which only renders on the gallery.
        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_value "$APP_PORT" database-photo-count "photos"

        send_command "$APP_PORT" click '{"dataId":"database-photo-count"}' || exit 1

        # The dialog carries its own copy of the summary view, so it runs the get-database-summary task again and logs the line a
        # second time.
        wait_for_log "$TMP_DIR" "Database summary loaded:"
        wait_for_value "$APP_PORT" database-summary-dialog "Consolidate into remote"

        send_command "$APP_PORT" click '{"dataId":"database-summary-dialog-close"}' || exit 1
        wait_for_value_gone "$APP_PORT" database-summary-dialog "Consolidate into remote" || exit 1
        log_success "The navbar photo count opens the database summary and the close button dismisses it"
        ;;
esac

check_no_errors "$TMP_DIR"

# Restart, and the database the user was in opens again on its own. Nothing is sent between the app starting and the log line, so the
# open is the app's own doing, which is the whole assertion.
stop_app "$APP_PORT" "$TMP_DIR"

# The relaunched app starts a fresh app.log, so the cursor from the first run points past the end of it.
reset_log_cursor "$TMP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_log "$TMP_DIR" "Database opened" 60
log_success "The database opened by itself after a restart"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 3 passed: open-database"
