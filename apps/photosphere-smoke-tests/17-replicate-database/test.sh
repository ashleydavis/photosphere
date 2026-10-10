#!/bin/bash

# Registers a source database on the Databases page and replicates it from the Replicate dialog, partial and then full. On a desktop
# the source is created with the CLI with one asset, the replicas' files are checked on disk and each replica is opened and loads the
# asset. On a phone the source is copied into the app's sandbox and the replica lives there too, out of the host's sight, so the files
# are not checked on disk and a second replication of the same source covers the engine pool that once dropped it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 17 "replicate-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

IMAGES_DIR="$REPO_DIR/test/multiple-files"
SOURCE_DB="$TMP_DIR/source-db"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        # Clear any replica from a previous run so the destination starts empty (replicating onto an unrelated existing database is
        # refused without --force).
        "${PLATFORM}_reset_path" "dest-partial"
        "${PLATFORM}_reset_path" "dest-full"
        log_info "Pre-creating an empty source database with the CLI..."
        create_database "$SOURCE_DB"
        SOURCE_PATH="$("${PLATFORM}_app_path" "source-db")"
        DEST_PARTIAL="$("${PLATFORM}_app_path" "dest-partial")"
        DEST_FULL="$("${PLATFORM}_app_path" "dest-full")"
        ;;
    *)
        log_info "Pre-creating the source database with one fixture..."
        create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"
        SOURCE_PATH="$SOURCE_DB"
        DEST_PARTIAL="$TMP_DIR/dest-partial"
        DEST_FULL="$TMP_DIR/dest-full"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$SOURCE_DB" "source-db"
        ;;
esac

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Register the source database on the Manage Databases page.
case "$PLATFORM" in
    android|ios)
        # The Add button is in the page's actions menu on a phone.
        send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
        ;;
esac
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
send_command "$APP_PORT" type "$(jq -cn --arg text "$SOURCE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

case "$PLATFORM" in
    android|ios)
        # Confirming the dialog registers the entry and then opens that database, which emits "Database opened" and then a second
        # "Databases page loaded" render. wait_for_log carries a cursor, so waiting for the render first would move the cursor past
        # the "Database opened" that preceded it and the wait for that would time out. The navigation cannot be relied on to produce
        # a render of its own either: the auto-open leaves the app on the databases page already.
        wait_for_log "$TMP_DIR" "Database opened"
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1

        # The open re-renders the card list, so it has to settle before the menu is opened: otherwise it lands mid-test and tears the
        # menu down before the action can be clicked.
        wait_for_value "$APP_PORT" database-photo-count "photos"
        wait_for_log "$TMP_DIR" "Databases page loaded"

        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        ;;
    *)
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"
        ;;
esac

# Partial replication.
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$DEST_PARTIAL" '{dataId: "replicate-dest-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

wait_for_log "$TMP_DIR" "Replication completed for"

case "$PLATFORM" in
    android|ios)
        # Replicate a second time. A replication tags its task queue with the source database's path and shuts that queue down when it
        # finishes, which cancels the source. The engine pool used to remember a cancelled source for the life of the app, so a second
        # replication was discarded before it ran: no error, no log line, the dialog simply sat there.
        send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"

        send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Replicate database dialog opened"
        send_command "$APP_PORT" type "$(jq -cn --arg text "$("${PLATFORM}_app_path" "dest-second")" '{dataId: "replicate-dest-path-input", text: $text}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Replication completed for"
        log_success "A second replication of the same database ran, rather than being silently dropped"
        ;;
    *)
        if [ ! -f "$DEST_PARTIAL/.db/files.dat" ]; then
            log_error "Partial replication did not produce $DEST_PARTIAL/.db/files.dat"
            exit 1
        fi
        if [ ! -f "$DEST_PARTIAL/.db/config.json" ]; then
            log_error "Partial replication did not produce $DEST_PARTIAL/.db/config.json"
            exit 1
        fi
        if ! grep -q "\"origin\"" "$DEST_PARTIAL/.db/config.json"; then
            log_error "Partial replication config.json does not contain origin"
            cat "$DEST_PARTIAL/.db/config.json"
            exit 1
        fi

        # The stored origin must be exactly the source path the user supplied to the dialog, otherwise the partial replica's lazy-fetch
        # logic will route to a bad path on load.
        ACTUAL_ORIGIN="$(jq -r '.origin' "$DEST_PARTIAL/.db/config.json")"
        if [ "$ACTUAL_ORIGIN" != "$SOURCE_DB" ]; then
            log_error "Partial replica config.json origin does not match source path."
            log_error "  Expected: $SOURCE_DB"
            log_error "  Actual:   $ACTUAL_ORIGIN"
            cat "$DEST_PARTIAL/.db/config.json"
            exit 1
        fi
        log_success "Partial replication produced expected files"

        # Close the success dialog before opening the replica.
        send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

        # Open the partial replica and confirm its gallery loads with the same number of assets the source has.
        send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DEST_PARTIAL" '{path: $path}')" || exit 1
        wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
        log_success "The partial replica opened with 1 asset"

        # Full replication. Navigate away and back to force the databases page to remount (re-entering the same route does not
        # trigger "Databases page loaded" again). The wait on the secrets page is what makes the trip away real: without it the two
        # navigations are dispatched back to back and the app can go straight back to the route it was already on, which remounts
        # nothing and emits nothing.
        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"

        send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Replicate database dialog opened"

        send_command "$APP_PORT" type "$(jq -cn --arg text "$DEST_FULL" '{dataId: "replicate-dest-path-input", text: $text}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"replicate-mode-full"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

        # The replication registers itself as a background job, so it can be watched and cancelled from the right sidebar rather than
        # only from this dialog.
        DEST_FULL_NAME="$(basename "$DEST_FULL")"
        wait_for_log "$TMP_DIR" "Background job started: Replicating to $DEST_FULL_NAME"
        log_success "The replication registered as a background job"

        wait_for_log "$TMP_DIR" "Replication completed for"

        # The row goes when the work does. The job's finish and the dialog's "Replication completed" line come from the same completion
        # and either can be logged first, so the finish is looked for in the whole log rather than after the line waited for above.
        # Nothing is left behind in the navbar: a job that never cleared would sit there forever.
        wait_for_value "$APP_PORT" "navbar-jobs-count" "0" 30
        if ! grep -q "Background job finished: Replicating to $DEST_FULL_NAME" "$TMP_DIR/app.log"; then
            log_error "The replication's background job was never logged as finished"
            exit 1
        fi
        log_success "The background job cleared when the replication completed"

        if [ ! -s "$DEST_FULL/.db/files.dat" ]; then
            log_error "Full replication did not produce a non-empty $DEST_FULL/.db/files.dat"
            exit 1
        fi
        log_success "Full replication produced expected files"

        send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

        # Open the full replica and confirm its gallery loads with the same number of assets.
        send_command "$APP_PORT" open-database "$(jq -cn --arg path "$DEST_FULL" '{path: $path}')" || exit 1
        wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
        log_success "The full replica opened with 1 asset"
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 17 passed: replicate-database"
