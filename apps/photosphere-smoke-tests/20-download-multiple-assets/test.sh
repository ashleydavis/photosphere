#!/bin/bash

# Selects two assets in the gallery and downloads them from the right sidebar. On a desktop the folder dialog is answered through the
# remote control connection's pick-answer command and both saved files are checked to be the originals byte for byte. A phone hands a
# download to the system folder picker, which nothing outside the app can answer, so the test stages the picker's outcome with
# stage-export and checks the download completes.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 20 "download-multiple-assets"

trap 'cleanup_apps "$TMP_DIR"' EXIT

IMAGES_DIR="$REPO_DIR/test/multiple-files"
SOURCE_DB="$TMP_DIR/test-db"
DOWNLOAD_DIR="$TMP_DIR/downloads"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
esac

log_info "Pre-creating a database with two fixtures..."
create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png"

case "$PLATFORM" in
    android|ios)
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        ;;
    *)
        DATABASE_PATH="$SOURCE_DB"

        log_info "Writing databases.toml..."
        mkdir -p "$TMP_DIR/config"
        cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "test-db"
description = ""
path = "$SOURCE_DB"
TOML

        mkdir -p "$DOWNLOAD_DIR"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        # Copy the database into the app's sandbox.
        "${PLATFORM}_seed_database" "$SOURCE_DB" "test-db" || exit 1
        ;;
esac

log_info "Opening the database..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DATABASE_PATH" '{path: $path}')" || exit 1

# Assets load incrementally: the streamed asset events render the gallery and the load-assets task completes in either order, so a
# sequential wait for one then the other is racy. The gallery rendering the items is what the selection below needs, and the assets
# having loaded is verified by the download succeeding.
wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "The database opened and the gallery rendered"

# The selection checkboxes are hidden (display:none) until selecting mode is on, so the first item is selected with a long press, the
# same gesture a user makes. Once selecting mode is on every checkbox is visible and the second item is selected by clicking its
# checkbox. All thumbs share data-id="gallery-item-checkbox", so nth picks which one.
log_info "Selecting both gallery items..."
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}' || exit 1
send_command "$APP_PORT" click '{"dataId":"gallery-item-checkbox","nth":1}' || exit 1

log_info "Opening the right sidebar..."
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1

# Wait until the sidebar reports both assets selected before downloading. The driver handles each command independently, so on a slow
# machine the download click can overtake the checkbox click and download one asset instead of two.
wait_for_value "$APP_PORT" "download-selected-button" "Download 2 assets"

case "$PLATFORM" in
    android|ios)
        # The system folder picker (Android) or share sheet (iOS) cannot be answered from outside the app, so the outcome it would give is
        # staged for the next export. Everything above the picker or sheet stays real: the batch save task, the temporary files and the
        # host request.
        log_info "Staging the folder picker outcome and clicking Download 2 assets..."
        send_command "$APP_PORT" stage-export '{"exportOutcome":"shared"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1

        wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded"
        log_success "Download to folder completed"

        check_no_errors "$TMP_DIR"

        stop_app "$APP_PORT" "$TMP_DIR"

        log_success "Test 20 passed: download-multiple-assets"
        exit 0
        ;;
esac

log_info "Answering the folder dialog and clicking Download 2 assets..."
send_command "$APP_PORT" pick-answer "$(jq -cn --arg path "$DOWNLOAD_DIR" '{paths: [$path]}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"download-selected-button"}' || exit 1

wait_for_log "$TMP_DIR" "Download to folder completed: 2 assets downloaded"
log_success "Download to folder completed"

for filename in test-1.jpeg test-2.png; do
    if [ ! -f "$DOWNLOAD_DIR/$filename" ]; then
        log_error "Expected downloaded file not found: $DOWNLOAD_DIR/$filename"
        log_error "Contents of $DOWNLOAD_DIR:"
        ls -la "$DOWNLOAD_DIR" || true
        exit 1
    fi
done
log_success "Both downloaded files exist in $DOWNLOAD_DIR"

for filename in test-1.jpeg test-2.png; do
    if ! cmp -s "$IMAGES_DIR/$filename" "$DOWNLOAD_DIR/$filename"; then
        log_error "The downloaded file does not match the original."
        log_error "  Original: $IMAGES_DIR/$filename"
        log_error "  Downloaded: $DOWNLOAD_DIR/$filename"
        exit 1
    fi
done
log_success "Both downloaded files match the originals"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 20 passed: download-multiple-assets"
