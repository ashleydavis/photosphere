#!/bin/bash

# The database named by last_opened_path in the databases section of state.yaml is reopened on launch, and closing it clears the key so
# the next launch lands on the welcome screen. On a desktop the config is written beside the app's settings and the close is checked in that file. On a phone
# the config is written into the sandbox and three launches cover it: a config naming a last database opens it on launch alone, a
# config without one stays on the welcome screen, and opening a database from the sidebar records it so the next launch reopens it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 40 "reopen-last-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

FIXTURE_NAME="50-assets"
FIXTURE_DB="$REPO_DIR/test/dbs/$FIXTURE_NAME"

case "$PLATFORM" in
    android|ios)
        # Start from nothing on the device, so the config seeded below is the whole of the state this depends on.
        "${PLATFORM}_reset_app_state" || exit 1
        "${PLATFORM}_seed_database" "$FIXTURE_DB" "$FIXTURE_NAME" || exit 1
        FIXTURE_PATH="$("${PLATFORM}_app_path" "$FIXTURE_NAME")"

        # 1. A config naming a last database opens it on launch. Seeded before the app starts, because the app reads it once.
        "${PLATFORM}_seed_databases_config" \
            "[{\"name\":\"$FIXTURE_NAME\",\"path\":\"$FIXTURE_PATH\"}]" \
            "[\"$FIXTURE_NAME\"]" \
            "$FIXTURE_PATH" || exit 1

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # The test taps nothing here, so the gallery filling comes from last_opened_path alone.
        wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1
        log_success "The seeded database opened on launch with nothing tapped"

        stop_app "$APP_PORT" "$TMP_DIR"
        reset_log_cursor "$TMP_DIR"

        # 2. A config naming no last database stays on the welcome screen, which the tests that seed a list without one rely on.
        "${PLATFORM}_seed_databases_config" \
            "[{\"name\":\"$FIXTURE_NAME\",\"path\":\"$FIXTURE_PATH\"}]" \
            "[\"$FIXTURE_NAME\"]" || exit 1

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        wait_for_value "$APP_PORT" "no-database-loaded" "." || exit 1
        log_success "A config naming no last database left the app on the welcome screen"

        # 3. Opening a database records it, so the next launch reopens it. Opened from the sidebar rather than with the open-database
        # command, which never reaches the code that records the path.
        send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
        wait_for_value "$APP_PORT" "open-recent-database-button-0" "$FIXTURE_NAME" || exit 1
        send_command "$APP_PORT" click '{"dataId":"open-recent-database-button-0"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1

        # The path is written after the gallery has already filled, so the file is read back rather than assumed.
        last_database_recorded=false
        for _attempt in $(seq 1 60); do
            if read_config_file state.yaml | grep -q "last_opened_path"; then
                last_database_recorded=true
                break
            fi
            sleep 1
        done

        if [ "$last_database_recorded" != "true" ]; then
            log_error "Opening a database did not record it in state.yaml:"
            read_config_file state.yaml
            exit 1
        fi

        stop_app "$APP_PORT" "$TMP_DIR"
        reset_log_cursor "$TMP_DIR"

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1
        log_success "The database opened in the app was reopened on the next launch"

        check_no_errors "$TMP_DIR" || exit 1
        ;;
    *)
        CONFIG_FILE="$TMP_DIR/config/databases.toml"
        STATE_FILE="$TMP_DIR/config/state.yaml"

        # A database of the user's own sits beside the fixture so the close can be shown to clear last_opened_path and leave the
        # database list and the recents as they were.
        log_info "Pre-creating a second database with the CLI..."
        create_database "$TMP_DIR/other-db"

        log_info "Writing databases.toml and a state.yaml naming the fixture as the last database..."
        "${PLATFORM}_seed_databases_config" \
            "$(jq -cn --arg fixture "$FIXTURE_DB" --arg other "$TMP_DIR/other-db" '[{name: "50-assets", path: $fixture}, {name: "other-db", path: $other}]')" \
            '["50-assets"]' \
            "$FIXTURE_DB" || exit 1

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # The test opens no database here, so the gallery filling comes from last_opened_path having been read.
        wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1

        # Close it from the UI and the key goes with it. The close item lives in the right sidebar, which has to be opened first.
        send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
        wait_for_value "$APP_PORT" "close-database-button" "Close database" || exit 1
        send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1
        wait_for_value "$APP_PORT" "no-database-loaded" "Welcome to Photosphere" || exit 1

        # The file is written after the page has already switched screens, so poll for it.
        last_database_cleared=false
        for _attempt in $(seq 1 60); do
            if ! grep -q "last_opened_path" "$STATE_FILE"; then
                last_database_cleared=true
                break
            fi
            sleep 0.5
        done

        if [ "$last_database_cleared" != "true" ]; then
            log_error "last_opened_path is still in $STATE_FILE after the database was closed:"
            cat "$STATE_FILE"
            exit 1
        fi

        # Clearing it must leave the databases list and the recents as they were, which proves the close rewrote one field.
        if ! grep -q 'name = "50-assets"' "$CONFIG_FILE" \
            || ! grep -q 'name = "other-db"' "$CONFIG_FILE" \
            || ! grep -q 'recent_names' "$STATE_FILE"; then
            log_error "Closing the database damaged the rest of $CONFIG_FILE or $STATE_FILE:"
            cat "$CONFIG_FILE" "$STATE_FILE"
            exit 1
        fi

        check_no_errors "$TMP_DIR"

        stop_app "$APP_PORT" "$TMP_DIR"
        ;;
esac

log_success "Test 40 passed: reopen-last-database"
