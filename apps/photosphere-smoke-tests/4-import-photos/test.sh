#!/bin/bash

# Imports two fixture images into an empty database and expects the gallery to show them. On a desktop the images are dropped on the
# import page's drop zone with the control connection's drop command, which records the drop with the core as the native app does for a
# real one. A phone has no drop, so the drop zone is hidden and a "Select photos" button opens the native picker. The picker cannot be
# automated, so the control connection's pick-answer command answers it with the paths of the fixture images, which are seeded into the
# app's files directory first; clicking import-files-button then imports exactly those paths. On a phone this exercises the full import
# pipeline: the import-assets orchestrator task spawns hash-file and upload-asset subtasks, and the images are processed with the
# bundled media tools.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 4 "import-photos"

IMAGES_DIR="$REPO_DIR/test/multiple-files"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # The empty target database (seeded from the checked-in no-assets fixture) and its name under the app's files directory.
        DB_NAME="import-target"

        # Stage the two fixture images so only they (not the large archive and video siblings) are seeded.
        STAGE_DIR="$TMP_DIR/import-images"
        mkdir -p "$STAGE_DIR"
        cp "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png" "$STAGE_DIR/"

        # Wipe everything the app has stored on the device (its storage, the web view's data and the keychain) so this scenario starts
        # from a known state. Done before launch, with the app stopped, so nothing can write state back underneath it.
        "${PLATFORM}_reset_app_state" || exit 1

        # Seed the empty database, the two images into the app's import temp directory, and the database's config-list entry.
        "${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/no-assets" "$DB_NAME" || exit 1
        "${PLATFORM}_seed_database" "$STAGE_DIR" ".import-tmp" || exit 1
        DB_PATH="$("${PLATFORM}_app_path" "$DB_NAME")"
        IMPORT_TMP_PATH="$("${PLATFORM}_app_path" ".import-tmp")"
        "${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_PATH\"}]" || exit 1
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

click_sidebar_item "$APP_PORT" open-database || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

# "Load assets task completed" only fires after the database opens, so it confirms the open on its own. Do not also wait for the
# "Database opened" line first: it is logged on a different path than the load line, so under load it can land after it, advancing
# wait_for_log's cursor past the load line and causing a spurious timeout.
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

case "$PLATFORM" in
    android|ios)
        # Answer the picker, then click the picker button so pickFiles resolves with the paths and the import-assets task runs.
        send_command "$APP_PORT" pick-answer "{\"paths\":[\"$IMPORT_TMP_PATH/test-1.jpeg\",\"$IMPORT_TMP_PATH/test-2.png\"]}" || exit 1
        send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
        ;;
    *)
        send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}" || exit 1
        ;;
esac

wait_for_log "$TMP_DIR" "2 assets imported"

# The gallery must now show the two imported assets.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"

case "$PLATFORM" in
    android|ios)
        # Thumbnail fetches for freshly imported assets go through the asset-serving layer; ignore only those.
        check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1
        ;;
    *)
        check_no_errors "$TMP_DIR"
        ;;
esac

log_success "Test 4 passed: import-photos"
