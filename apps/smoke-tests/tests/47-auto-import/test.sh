#!/bin/bash

# Automatic import on a phone, end to end and for real.
#
# A photo is put into the device photo library from outside the app (pushed to DCIM and scanned into
# MediaStore), the photo permission is granted from outside the app, and then automatic import is
# switched on through the settings card. Nothing else is touched: the app has to create its own
# default database, notice the photo, and import it.
#
# The point of the test is the part that is different on mobile. The loop runs in the WebView rather
# than in a worker task, because the embedded engine pool has three slots and the asset server holds
# one for the life of the app: a long-running orchestrator task in a second slot leaves nothing for
# the tasks the import it queues needs in turn, and the import waits for a slot that can never come
# free. That failure looks exactly like success from outside (the setting is on, the task is
# running), which is why this test waits for the photo to land in the gallery rather than for the
# task to start.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 47 "auto-import"

# Android only, for now. Putting a photo into the simulator's library is straightforward
# (`simctl addmedia`), but there is no supported way to take one out again, and a test that leaves a
# photo behind poisons every run after it, including other suites sharing the simulator. Skipping is
# said out loud rather than passing quietly, because a test that reports success without running is
# worse than one that is missing.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: automatic import is covered on Android only. The iOS simulator has no supported way to remove a seeded photo, so this test would leave one behind for every run after it."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The photos put into the device library, named so a parallel run cannot collide with them. The
# second is declared here so the exit trap can clean it up whether or not the test got that far.
PHOTO_NAME="psphere-auto-import-$$.jpeg"
SECOND_PHOTO_NAME="psphere-auto-import-second-$$.png"

# Reads the text of a data-id element through the control bridge (empty when absent).
read_value() {
    local port="$1"
    local data_id="$2"
    local response
    response=$(curl -sf "http://$BRIDGE_HOST:$port/get-value?dataId=$data_id" 2>/dev/null || true)
    echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/'
}

# Waits for the hash cache file the imports should have written into the app's sandbox.
#
# The directory under hash-cache/ is named by a hash of the database path, and the app makes its own
# database here, so the name is not known to the test and the tree is listed rather than the file
# named. `ls -R` is used instead of a glob because the shell `adb shell` gives us runs as the shell
# user, which cannot read the app's private storage, so a pattern would come back unexpanded.
#
# It is polled rather than read once because the save happens as the import finishes, which is
# around the same moment as the line the test waited for.
wait_for_hash_cache() {
    local ticks=30
    while [ "$ticks" -gt 0 ]; do
        if adb shell run-as "$APP_ID" ls -R files/tmp/photosphere/hash-cache 2>/dev/null | tr -d '\r' | grep -q "hash-cache-x.dat"; then
            return 0
        fi
        sleep 1
        ticks=$((ticks - 1))
    done
    return 1
}

# Removes the photo from the device library however the test ends, so the next run starts clean and
# a failed run does not leave a photo behind for the one after it to find.
on_exit() {
    local exit_code=$?
    "${PLATFORM}_remove_media" "$PHOTO_NAME" 2>/dev/null || true
    "${PLATFORM}_remove_media" "$SECOND_PHOTO_NAME" 2>/dev/null || true
    stop_app "$APP_PORT" "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

# Wipe everything the app has stored on the device, so this starts with no databases, no settings and
# no default database. Automatic import creating its own is part of what is under test.
"${PLATFORM}_reset_app_state" || exit 1

# Sweep up anything a previous run of this test left behind. A run killed outright never reaches its
# exit trap, and a photo it left would be imported by this one and throw its counts out.
"${PLATFORM}_remove_media_matching" "psphere-auto-import-" || true

# Put the photo into the device photo library before the app starts, so it is part of the library the
# backfill walks rather than something that arrives mid-run.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$PHOTO_NAME" || exit 1

# Grant the photo permission from outside the app. The system dialog cannot be tapped by a test, and
# the app's own request resolves straight away once the permission is already held.
"${PLATFORM}_grant_media_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Switch automatic import on through the settings card, which is the only thing the user does.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The app makes its own default database, because there was not one.
wait_for_log "$TMP_DIR" "Creating the default photo database" || exit 1
wait_for_log "$TMP_DIR" "Starting automatic import into" || exit 1

# The photo has to actually arrive. This is the line the engine-pool deadlock never reached: the loop
# would report zeros forever because the import it queued could not get a slot.
wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

# The photo has to be in the database the app made, not merely reported as imported. Opening it is
# also what the Import page needs before it will run its tool check and become ready.
send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded" 120 || exit 1

send_command "$APP_PORT" navigate '{"page":"/import"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready" || exit 1

# A second photo, put into the library while the app is running, has to be noticed and imported on
# its own. That is the fast lane rather than the backfill, and it is the whole point of the feature:
# a photo the user has just taken should appear without them doing anything.
#
# It also fills the Import page's panel, which only shows what it has been told while it is on
# screen. The panel is the shared one the desktop uses and it reads task messages, so this is what
# proves the progress of an import running in the embedded engine still reaches the interface.
"${PLATFORM}_seed_media" "$REPO_DIR/test/multiple-files/test-2.png" "$SECOND_PHOTO_NAME" || exit 1

# The panel appears on the first progress message it is told about, which is the one sent as the
# batch is handed over, so it is waited for before the count that follows it. Waiting the other way
# round moves the log cursor past this line and then times out on it.
wait_for_log "$TMP_DIR" "Import progress shown" 180 || exit 1

# One imported, again, rather than two. An import reads its sources to the end and stops, and the app
# starts another a short while later, so every run counts only what it did: the run that takes in this
# second photo reports one, exactly as the run that took in the first one did. That both photos are in
# the database is proven below, by the gallery holding two.
wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

# Two real imports have now run, so the hash cache has to hold something. It never did on a phone:
# the embedded engine's fs shim had no `open`, so taking the cache's update lock threw a TypeError,
# HashCache.save() swallowed it, and the cache directory stayed permanently empty. Nothing about the
# import looked wrong from outside, and every run re-exported and re-hashed every photo it had
# already imported, which on 2,186 photos is about an hour of work per run instead of a second.
if ! wait_for_hash_cache; then
    log_error "The hash cache was never written: no hash-cache-x.dat under files/tmp/photosphere/hash-cache after two imports. Every import will re-hash every photo it has already imported."
    exit 1
fi
log_info "Hash cache written to the app sandbox"

# The second photo has to land in the gallery without the database being reopened, which is what the
# arrival messages are for. A photo that only shows up after a restart is not a photo the user saw
# arrive.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets" 60 || exit 1

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 47 passed: auto-import"
