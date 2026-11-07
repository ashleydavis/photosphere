#!/bin/bash

# Creates two databases in a row from the New Database dialog and proves each lands in its own directory and opens. On a desktop each
# path is filled by Browse (the folder dialog's answer is staged with the control connection's pick-answer command, because a test
# cannot drive the native dialog). On a phone there is no folder dialog for a database location: the dialog must not offer Browse, and
# the user types a name, which the app resolves to a directory in its own data directory. If both databases resolved to the same
# directory, the second create would land on the first's non-empty directory and fail.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 47 "create-database-no-collision"

trap 'cleanup_apps "$TMP_DIR"' EXIT

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

#
# Creates the database with the given name through the New Database dialog, the way a user on this platform does, then checks it was
# created in the app's data directory and opened.
# Usage: create_database_from_dialog <name>
#
create_database_from_dialog() {
    local name="$1"
    local db_path
    db_path="$("${PLATFORM}_app_path" "$name")"

    # Create needs an empty directory at the target path.
    "${PLATFORM}_reset_path" "$name" || exit 1

    click_sidebar_item "$APP_PORT" new-database || exit 1
    wait_for_log "$TMP_DIR" "Create database dialog opened"
    send_command "$APP_PORT" type "$(jq -cn --arg text "$name" '{dataId: "database-name-input", text: $text}')" || exit 1

    case "$PLATFORM" in
        android|ios)
            # The dialog is on screen once its Create button reads back, so an empty Browse read is the button being absent and not
            # the dialog still rendering.
            wait_for_value "$APP_PORT" "create-database-confirm" "Create"
            local browse
            browse="$(read_value "$APP_PORT" "database-browse-button")"
            if [ -n "$browse" ]; then
                log_error "The New Database dialog offers Browse on a phone ('$browse'), where there is no folder dialog for a database location"
                exit 1
            fi
            send_command "$APP_PORT" type "$(jq -cn --arg text "$name" '{dataId: "database-path-input", text: $text}')" || exit 1
            wait_for_value "$APP_PORT" "database-path-input" "$name"
            ;;
        *)
            send_command "$APP_PORT" pick-answer "$(jq -cn --arg path "$db_path" '{paths: [$path]}')" || exit 1
            send_command "$APP_PORT" click '{"dataId":"database-browse-button"}' || exit 1
            # Browse fills the path field from an async handler, and Create stays disabled while the field is empty, so a Create click
            # sent before the path lands is swallowed and nothing happens at all. The wait also asserts the field reads this database's
            # own path, so a Browse that handed back an earlier path fails here.
            wait_for_value "$APP_PORT" "database-path-input" "$db_path"
            ;;
    esac

    send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
    # Create opens the new database before the dialog logs that it was created, so the two lines are waited for in that order.
    wait_for_log "$TMP_DIR" "Database opened: $name"
    wait_for_log "$TMP_DIR" "Database created"

    case "$PLATFORM" in
        android|ios)
            if ! "${PLATFORM}_path_exists" "$name/.db"; then
                log_error "Expected the database to be created at $db_path"
                exit 1
            fi
            ;;
        *)
            if [ ! -d "$db_path/.db" ]; then
                log_error "Expected the database to be created at $db_path"
                exit 1
            fi
            ;;
    esac

    # "Database created" is logged just before the dialog is told to close, and a New database sent before that close has rendered asks
    # for a dialog that is still open, which does nothing. A user cannot be that quick, so the next request waits for the dialog to go.
    wait_for_value_gone "$APP_PORT" "create-database-confirm" "Create" || exit 1
}

create_database_from_dialog "db-one"
create_database_from_dialog "db-two"

# A collision would have failed the second create (non-empty directory) and logged an error.
check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 47 passed: create-database-no-collision"
