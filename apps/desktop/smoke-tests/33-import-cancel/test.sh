#!/bin/bash

# Cancelling an import must stop it part way and leave importing usable afterwards. A batch big
# enough to still be running is dropped in, cancelled, and then a second import is run to completion.
#
# Import tasks are tagged with the session id, and cancelling calls cancelTasks on that tag. Unlike
# the LAN-share tasks each import session gets a fresh id, so the restart here is not covering the
# same "is a cancelled tag still usable" question that 29 to 32 cover. What it does cover is that
# cancelling stops the work rather than merely relabelling the screen, and that the import feature
# survives a cancellation.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 33 "import-cancel"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# The batch has to be big enough that it is still running when the Cancel button is clicked. Each
# file is hashed, thumbnailed and written, so this many takes well over the second or two the test
# needs to see the button and click it.
BATCH_SIZE=60

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes
cd "$DESKTOP_DIR"

mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
EOF

# Build the batch. Each copy is given a distinct name so the importer treats it as its own asset
# rather than collapsing them, and the images are copied into a fresh directory under tmp.
mkdir -p "$TMP_DIR/batch"
batch_paths=""
file_index=0
while [ "$file_index" -lt "$BATCH_SIZE" ]; do
    cp "$IMAGES_DIR/test-1.jpeg" "$TMP_DIR/batch/batch-$file_index.jpeg"
    if [ -n "$batch_paths" ]; then
        batch_paths="$batch_paths,"
    fi
    batch_paths="$batch_paths\"$TMP_DIR/batch/batch-$file_index.jpeg\""
    file_index=$((file_index + 1))
done

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}'
wait_for_log "$TMP_DIR" "Import page ready"

# --- 1. Start the batch and cancel it while it runs. ---

send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[$batch_paths]}"

# The Cancel button only renders while the import is running, so waiting for it is how the test knows
# there is an import in flight to cancel.
wait_for_value "$APP_PORT" "import-cancel-button" "Cancel"

send_command "$APP_PORT" click '{"dataId":"import-cancel-button"}'

# The button goes away when the import leaves the running state.
elapsed=0
while [ "$elapsed" -lt 30 ]; do
    response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=import-cancel-button" 2>/dev/null || true)
    still_running=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ "$still_running" != "Cancel" ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ "$still_running" = "Cancel" ]; then
    log_error "The import is still running 30s after it was cancelled"
    exit 1
fi
log_success "The cancelled import stopped"

# Give any task that was already in flight when the cancel landed time to finish writing, so the
# count read below is settled rather than caught mid-write.
sleep 5

send_command "$APP_PORT" navigate '{"page":"/"}'
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

send_command "$APP_PORT" click '{"dataId":"import-button"}'

# A cancelled import leaves the page showing its result list, and Clear is what takes it back to the
# drop zone. Waiting for the button rather than a log line because the page-ready event only fires
# when the tool check flips to available, which it does not do on a revisit.
wait_for_value "$APP_PORT" "import-clear-button" "Clear"
send_command "$APP_PORT" click '{"dataId":"import-clear-button"}'

# Clear puts the page back to idle, which restarts the media-tool check, and drag and drop stays off
# until that check reports the tools are available. The drop zone is on screen before then, so
# dropping without this wait lands on a zone that silently ignores it.
wait_for_log "$TMP_DIR" "Import page ready"

send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-2.png\"]}"
wait_for_log "$TMP_DIR" "1 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded:"

imported_after_restart=$(grep -o "Gallery loaded: [0-9]* assets" "$TMP_DIR/app.log" | tail -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
if [ "$imported_after_restart" -le "$imported_after_cancel" ]; then
    log_error "The import run after the cancelled one added nothing (gallery went from $imported_after_cancel to $imported_after_restart)"
    exit 1
fi
log_success "An import started after a cancelled one ran to completion"

check_no_errors "$TMP_DIR"

log_success "Test 33 passed: import-cancel"
