#!/bin/bash

# Opens an asset in the AssetView and clicks Download. On a desktop the save dialog is answered through the test control connection's
# pick-answer command and the saved file is checked to be the original byte for byte. A phone hands a download to the system save
# picker, which nothing outside the app can answer, so the test stages the picker's outcome with stage-export and checks the download
# completes.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 19 "download-single-asset"

case "$PLATFORM" in
    ios)
        log_info "SKIP: the iOS shell has no way to stage the share sheet outcome yet. Skipping."
        exit 77
        ;;
esac

trap 'cleanup_apps "$TMP_DIR"' EXIT

IMAGES_DIR="$REPO_DIR/test/multiple-files"
SOURCE_DB="$TMP_DIR/test-db"
DOWNLOAD_DIR="$TMP_DIR/downloads"
DOWNLOAD_FILE="$DOWNLOAD_DIR/test-1.jpeg"

case "$PLATFORM" in
    android)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
esac

log_info "Pre-creating a database with one fixture..."
create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"

case "$PLATFORM" in
    android)
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
    android)
        # Copy the database into the app's sandbox.
        "${PLATFORM}_seed_database" "$SOURCE_DB" "test-db"
        ;;
esac

log_info "Opening the database..."
send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DATABASE_PATH" '{path: $path}')" || exit 1

# Assets load incrementally: the streamed asset messages render the gallery and the load-assets task completes in either order, so a
# sequential wait for one then the other is racy. The gallery rendering the item is what the click below needs, and the asset having
# loaded is verified by the download succeeding.
wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "The database opened and the gallery rendered"

# A real click is not enough to open the AssetView: the thumb uses a long press hook, which only reacts to mousedown and mouseup.
log_info "Opening the AssetView with a long-press click on the first gallery thumb..."
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"
log_success "The AssetView is open"

case "$PLATFORM" in
    android)
        # The system save picker cannot be answered from outside the app, so the outcome it would give is staged for the next export.
        # Everything above the picker stays real: the save task, the temporary file and the host request.
        log_info "Staging the save picker outcome and clicking the Download icon..."
        send_command "$APP_PORT" stage-export '{"exportOutcome":"shared"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1

        wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg"
        log_success "The download completed event was logged"

        check_no_errors "$TMP_DIR"

        stop_app "$APP_PORT" "$TMP_DIR"

        log_success "Test 19 passed: download-single-asset"
        exit 0
        ;;
esac

# The answer is used for the next dialog only: the save dialog the Download click opens.
log_info "Answering the save dialog and clicking the Download icon..."
send_command "$APP_PORT" pick-answer "$(jq -cn --arg path "$DOWNLOAD_FILE" '{paths: [$path]}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"download-asset-button"}' || exit 1

wait_for_log "$TMP_DIR" "Download completed: test-1.jpeg"
log_success "The download completed event was logged"

if [ ! -f "$DOWNLOAD_FILE" ]; then
    log_error "Expected downloaded file not found: $DOWNLOAD_FILE"
    log_error "Contents of $DOWNLOAD_DIR:"
    ls -la "$DOWNLOAD_DIR" || true
    exit 1
fi
log_success "The downloaded file exists at $DOWNLOAD_FILE"

if ! cmp -s "$IMAGES_DIR/test-1.jpeg" "$DOWNLOAD_FILE"; then
    log_error "The downloaded file does not match the original."
    log_error "  Original: $IMAGES_DIR/test-1.jpeg"
    log_error "  Downloaded: $DOWNLOAD_FILE"
    exit 1
fi
log_success "The downloaded file matches the original byte for byte"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 19 passed: download-single-asset"
