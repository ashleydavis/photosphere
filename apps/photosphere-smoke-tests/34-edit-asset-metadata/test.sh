#!/bin/bash

# Edits an asset's metadata in the UI and confirms it reached the database.
#
# This covers the gallery EDIT path: persistDatabaseOps in packages/user-interface/src/context/asset-database-source.tsx POSTs the
# metadata ops to /apply-database-ops on the app's own asset server. Nothing else in the suite exercises that route. Moving assets
# between databases goes through a background move-assets task and never touches the endpoint.
#
# The description input is bound to React state that onUpdateDescription sets before the POST is even sent, so reading it in place
# passes whether or not a single byte reached the disk. On a desktop the database is read back with the CLI, which is a separate
# process opening the database from scratch. On a phone the database cannot be read from the host, so the database is closed and
# opened again, which throws the React state away and loads the record from storage. Either way only a persisted edit passes.
#
# The AssetView is closed before the check because that is what flushes the write: the description goes through a 500ms debounce, and
# AssetInfo's unmount effect flushes it. Waiting on a timer instead would be a race.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 34 "edit-asset-metadata"

SOURCE_DB="$TMP_DIR/test-db"
DESCRIPTION="Edited in the gallery"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        DB_NAME="edit-db"
        SOURCE_DB="$TMP_DIR/$DB_NAME"
        "${PLATFORM}_reset_app_state" || exit 1
        # Read after the reset: on iOS the reset reinstalls the app, which gives it a new data container, so a path read before it
        # names a container that no longer exists.
        OPEN_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"
        ;;
    *)
        OPEN_PATH="$SOURCE_DB"
        ;;
esac

# One asset is all this needs: the endpoint is the subject, not the volume.
log_info "Pre-creating database and importing a fixture..."
create_database "$SOURCE_DB" "$REPO_DIR/test/multiple-files/test-1.jpeg"

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        log_info "Writing databases.toml..."
        mkdir -p "$TMP_DIR/config"
        cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
TOML
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$SOURCE_DB" "$DB_NAME" || exit 1
        ;;
esac

log_info "Opening database..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$OPEN_PATH" '{path: $path}')" || exit 1
# Assets load incrementally, so the gallery rendering the item is the signal that the thumbnail can be clicked.
wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "Database opened with 1 asset"

# The thumb uses useLongPress, which only reacts to mousedown/mouseup, so a plain click is not enough.
log_info "Opening the AssetView..."
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

log_info "Typing a description into the info panel..."
send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$DESCRIPTION" '{dataId: "asset-description-input", text: $text}')" || exit 1

# The field holding the text proves only that the keystrokes reached React. It is asserted anyway, so that a failure below reads as
# "the edit did not persist" rather than "the typing never landed".
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The description was typed into the info panel"

# Closing unmounts AssetInfo, whose unmount effect flushes the debounced write.
log_info "Closing the AssetView to flush the write..."
send_command "$APP_PORT" click '{"dataId":"asset-view-close-button"}' || exit 1

# The app says when the write actually landed, so what reads the database next is not racing a write still in flight.
wait_for_log "$TMP_DIR" "Database ops applied"

case "$PLATFORM" in
    android|ios)
        # Closing the database destroys an unfinished write, which is why the wait above comes first.
        send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1
        wait_for_value "$APP_PORT" "no-database-loaded" "."
        log_success "The database was closed, so nothing about the edit is left in memory"

        send_command "$APP_PORT" open-database "$(jq -cn --arg path "$OPEN_PATH" '{path: $path}')" || exit 1
        wait_for_log "$TMP_DIR" "Gallery items rendered"
        send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
        wait_for_log "$TMP_DIR" "AssetView opened"
        send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1

        # The record was reloaded from storage, so this can only match if the metadata op reached the database and was applied.
        wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
        log_success "The edit survived closing and reopening the database, so it reached the database on disk"
        ;;
    *)
        log_info "Reading the asset back out of the database with the CLI..."
        ASSET_ID="$("$PHOTOSPHERE_ZIG_CLI" list --db "$SOURCE_DB" --yes 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
        if [ -z "$ASSET_ID" ]; then
            log_error "Could not find the asset's id in the output of 'psi list'."
            exit 1
        fi
        log_info "Asset id: $ASSET_ID"

        # Polled rather than read once: the POST may still be landing when the AssetView closes.
        INFO_OUTPUT=""
        FOUND=""
        for _attempt in $(seq 1 30); do
            INFO_OUTPUT="$("$PHOTOSPHERE_ZIG_CLI" info "$ASSET_ID" --db "$SOURCE_DB" --yes 2>&1)"
            if echo "$INFO_OUTPUT" | grep -qF "$DESCRIPTION"; then
                FOUND="1"
                break
            fi
            sleep 1
        done

        if [ -z "$FOUND" ]; then
            log_error "The edit never reached the database on disk."
            log_error "'psi info $ASSET_ID' does not report the description \"$DESCRIPTION\". It said:"
            echo "$INFO_OUTPUT" | sed 's/^/  /'
            exit 1
        fi
        log_success "The edit reached the database on disk: 'psi info' reports the new description"
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 34 passed: edit-asset-metadata"
