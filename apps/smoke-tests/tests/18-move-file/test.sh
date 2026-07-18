#!/bin/bash

# Opens a database, selects an asset, and moves it to another database.
# Electron uses checkbox selection and verifies both DBs after the move.
# Mobile uses long-press selection.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 18 "move-file"

TMP_DIR="$TEST_DIR/tmp"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    SOURCE_DB="$TMP_DIR/source-db"
    DEST_DB="$TMP_DIR/dest-db"

    log_info "Pre-creating source database and importing a fixture..."
    create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"

    log_info "Pre-creating destination database..."
    create_database "$DEST_DB"

    log_info "Writing databases.toml with both entries..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "source-db"
description = ""
path = "$SOURCE_DB"

[[databases]]
name = "dest-db"
description = ""
path = "$DEST_DB"
EOF

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    log_info "Opening source database..."
    send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
    log_success "Source database opened with 1 asset"

    wait_for_log "$TMP_DIR" "Gallery items rendered"
    log_success "Gallery items are in the DOM"

    log_info "Selecting the first gallery item..."
    send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox"}' || exit 1

    log_info "Opening right sidebar..."
    send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1

    log_info "Clicking Move to dest-db..."
    send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}' || exit 1

    wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved"
    log_success "Move to database completed"

    log_info "Opening destination database to verify..."
    send_command "$APP_PORT" open-database "{\"path\":\"$DEST_DB\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
    log_success "Destination database has 1 asset"

    log_info "Opening source database to verify it is empty..."
    send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
    log_success "Source database is empty after move"

    check_no_errors "$TMP_DIR"

    log_success "Test 18 passed: move-file"
else
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/source-db" "$REPO_DIR/test/multiple-files/test-1.jpeg"
    create_database "$TMP_DIR/dest-db"
    seed_database "$TMP_DIR/source-db" "source-db"
    seed_database "$TMP_DIR/dest-db" "dest-db"
    send_command "$APP_PORT" seed-databases '{"databases":[{"name":"source-db","path":"source-db"},{"name":"dest-db","path":"dest-db"}]}' || exit 1

    send_command "$APP_PORT" open-database '{"path":"source-db"}' || exit 1
    wait_for_log "$TMP_DIR" "Gallery items rendered"

    send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}' || exit 1
    wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved"

    check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

    log_success "Test 18 passed: move-file"
fi
