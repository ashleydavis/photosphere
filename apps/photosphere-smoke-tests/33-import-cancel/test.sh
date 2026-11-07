#!/bin/bash

# Cancelling an import must stop it part way and leave importing usable afterwards. A batch big enough to still be running is picked
# in, cancelled, and then a second import is run to completion.
#
# Import tasks are tagged with the session id, and cancelling calls cancelTasks on that tag. Unlike the LAN-share tasks each import
# session gets a fresh id, so the restart here is not covering the same "is a cancelled tag still usable" question that the share
# cancel scenarios cover. What it does cover is that cancelling stops the work rather than merely relabelling the screen, and that the
# import feature survives a cancellation.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 33 "import-cancel"

trap 'cleanup_apps "$TMP_DIR"' EXIT

# The batch has to be big enough that it is still running when the Cancel button is clicked. Each file is hashed, thumbnailed and
# written, so this many full-size photos takes well over the second or two the test needs to see the button and click it. The 100x80
# test image is no use for this: a batch of them is imported in under a second, before the test can reach the button.
BATCH_SIZE=60

"${PLATFORM}_reset_app_state" || exit 1

log_info "Pre-creating database with CLI..."
create_database "$TMP_DIR/test-db"

# Build the batch. The importer imports a file's content once per scan and skips any other file in the same scan with the same hash, so
# a distinct name is not enough: each copy has its index appended after the end of the JPEG data, which makes its content, and so its
# hash, its own without changing the image. The images are copied into a fresh directory under tmp. The file imported after the cancel
# is staged beside them, and is left out of the batch's path list.
mkdir -p "$TMP_DIR/batch"
cp "$IMAGES_DIR/test-2.png" "$TMP_DIR/batch/"
batch_paths=""
file_index=0
while [ "$file_index" -lt "$BATCH_SIZE" ]; do
    cp "$REPO_DIR/test/test.jpg" "$TMP_DIR/batch/batch-$file_index.jpeg"
    printf '%s' "$file_index" >> "$TMP_DIR/batch/batch-$file_index.jpeg"
    file_index=$((file_index + 1))
done

# Seed the database and the staged files into the app's files directory, and register the database, from outside the app and before it
# starts. The batch's paths are the app's own paths to the staged files.
"${PLATFORM}_seed_database" "$TMP_DIR/test-db" "test-db" || exit 1
"${PLATFORM}_seed_database" "$TMP_DIR/batch" ".import-tmp" || exit 1
DB_PATH="$("${PLATFORM}_app_path" "test-db")"
IMPORT_TMP_PATH="$("${PLATFORM}_app_path" ".import-tmp")"
"${PLATFORM}_seed_databases_config" "[{\"name\":\"test-db\",\"path\":\"$DB_PATH\"}]" || exit 1
file_index=0
while [ "$file_index" -lt "$BATCH_SIZE" ]; do
    if [ -n "$batch_paths" ]; then
        batch_paths="$batch_paths,"
    fi
    batch_paths="$batch_paths\"$IMPORT_TMP_PATH/batch-$file_index.jpeg\""
    file_index=$((file_index + 1))
done

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

click_sidebar_item "$APP_PORT" open-database || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

# --- 1. Start the batch and cancel it while it runs. ---

send_command "$APP_PORT" pick-answer "{\"paths\":[$batch_paths]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1

# The Cancel button only renders while the import is running, so waiting for it is how the test knows there is an import in flight to
# cancel.
wait_for_value "$APP_PORT" "import-cancel-button" "Cancel"

send_command "$APP_PORT" click '{"dataId":"import-cancel-button"}' || exit 1

# The button goes away when the import leaves the running state.
wait_for_value_gone "$APP_PORT" "import-cancel-button" "Cancel" || {
    log_error "The import is still running after it was cancelled"
    exit 1
}
log_success "The cancelled import stopped"

# Give any task that was already in flight when the cancel landed time to finish writing, so the count read below is settled rather
# than caught mid-write.
sleep 5

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded:"

imported_after_cancel=$(grep -o "Gallery loaded: [0-9]* assets" "$TMP_DIR/app.log" | tail -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
if [ -z "$imported_after_cancel" ]; then
    log_error "Could not read the gallery asset count after the cancelled import"
    exit 1
fi
log_info "Assets imported before the cancel took effect: $imported_after_cancel of $BATCH_SIZE"

if [ "$imported_after_cancel" -ge "$BATCH_SIZE" ]; then
    log_error "The cancelled import still imported all $BATCH_SIZE files, so nothing was actually cancelled"
    exit 1
fi
log_success "The cancel stopped the batch part way through"

# --- 2. Import again and let it finish. ---

# The import page is reached from the navbar, which is on screen whatever the gallery holds. The gallery's own import button only exists
# while the gallery is empty, and how many files landed before the cancel took effect is not fixed.
send_command "$APP_PORT" click '{"dataId":"navbar-import-button"}' || exit 1

# A cancelled import leaves the page showing its result list, and Clear is what takes it back to the drop zone. Waiting for the button
# rather than a log line because the page-ready event only fires when the tool check flips to available, which it does not do on a
# revisit.
wait_for_value "$APP_PORT" "import-clear-button" "Clear"
send_command "$APP_PORT" click '{"dataId":"import-clear-button"}' || exit 1

# Clear puts the page back to idle, which restarts the media-tool check, and the picker button stays off until that check reports the
# tools are available. The button is on screen before then, so clicking without this wait lands on a button that silently ignores it.
wait_for_log "$TMP_DIR" "Import page ready"

send_command "$APP_PORT" pick-answer "{\"paths\":[\"$IMPORT_TMP_PATH/test-2.png\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "1 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded:"

imported_after_restart=$(grep -o "Gallery loaded: [0-9]* assets" "$TMP_DIR/app.log" | tail -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
if [ "$imported_after_restart" -le "$imported_after_cancel" ]; then
    log_error "The import run after the cancelled one added nothing (gallery went from $imported_after_cancel to $imported_after_restart)"
    exit 1
fi
log_success "An import started after a cancelled one ran to completion"

check_no_errors "$TMP_DIR"

log_success "Test 33 passed: import-cancel"
