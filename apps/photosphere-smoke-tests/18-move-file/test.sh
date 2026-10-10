#!/bin/bash

# Selects an asset in the gallery and moves it to another database from the right sidebar, then opens both databases and checks the
# asset left the source and arrived in the destination. On a desktop both databases are created with the CLI and databases.toml lists
# them. On a phone both are copied into the app's sandbox and registered, and the entries' paths are their sandbox-relative names.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 18 "move-file"

trap 'cleanup_apps "$TMP_DIR"' EXIT

IMAGES_DIR="$REPO_DIR/test/multiple-files"
SOURCE_DB="$TMP_DIR/source-db"
DEST_DB="$TMP_DIR/dest-db"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
esac

log_info "Pre-creating the source database with one asset and the empty destination database..."
create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"
create_database "$DEST_DB"

case "$PLATFORM" in
    android|ios)
        SOURCE_PATH="$("${PLATFORM}_app_path" "source-db")"
        DEST_PATH="$("${PLATFORM}_app_path" "dest-db")"
        ;;
    *)
        SOURCE_PATH="$SOURCE_DB"
        DEST_PATH="$DEST_DB"

        log_info "Writing databases.toml with both entries..."
        mkdir -p "$TMP_DIR/config"
        cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "source-db"
description = ""
path = "$SOURCE_DB"

[[databases]]
name = "dest-db"
description = ""
path = "$DEST_DB"
TOML
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        # Copy both databases into the sandbox and register both so the right sidebar offers dest-db as a move target.
        "${PLATFORM}_seed_database" "$SOURCE_DB" "source-db"
        "${PLATFORM}_seed_database" "$DEST_DB" "dest-db"
        "${PLATFORM}_seed_databases_config" "$(jq -cn --arg source "$SOURCE_PATH" --arg dest "$DEST_PATH" '[{name: "source-db", path: $source}, {name: "dest-db", path: $dest}]')" || exit 1
        ;;
esac

log_info "Opening the source database..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$SOURCE_PATH" '{path: $path}')" || exit 1
# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task complete in either order, so a
# sequential wait for one then the other is racy. Wait for the gallery to render the item, which is what is needed to select it.
wait_for_log "$TMP_DIR" "Gallery items rendered"

# The selection checkbox is hidden (display:none) until selecting mode is on, so the item is selected with a long press, the same
# gesture a user makes.
log_info "Selecting the first gallery item..."
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}' || exit 1

log_info "Opening the right sidebar and moving to dest-db..."
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}' || exit 1
wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved"
log_success "Move to database completed"

log_info "Opening the destination database to verify it holds the asset..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DEST_PATH" '{path: $path}')" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
log_success "The destination database has 1 asset"

log_info "Opening the source database to verify it is empty..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$SOURCE_PATH" '{path: $path}')" || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
log_success "The source database is empty after the move"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 18 passed: move-file"
