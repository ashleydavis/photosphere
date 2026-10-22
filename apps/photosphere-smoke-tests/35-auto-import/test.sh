#!/bin/bash

# Exercises automatic import end to end in the real app.
#
# On a desktop, switching it on creates the default private database, lists it, and marks it as the default; a file dropped into a
# watched folder is imported without the user doing anything; and the cleanup button deletes the source files the database already
# holds. The watched folder is set through the config file rather than through the folder picker, because a native folder dialog cannot
# be driven from here. Everything above the picker is the real code path: the setting, the main process reacting to it, the task, and
# the import.
#
# On a phone, a photo is put into the device photo library from outside the app (pushed to DCIM and scanned into MediaStore), the photo
# permission is granted from outside the app, and then automatic import is switched on through the settings card. Nothing else is
# touched: the app has to create its own default database, notice the photo, and import it. The part that is different on a phone is
# that the loop runs natively (a foreground service on Android) rather than as one long-running task, because the task slots are few
# and the asset server holds one for the life of the app: an orchestrator task in a second slot leaves nothing for the tasks the import
# it queues needs in turn, and the import waits for a slot that can never come free. That failure looks exactly like success from
# outside (the setting is on, the task is running), which is why the phone branch waits for the photo to land in the gallery rather
# than for the task to start. What happens once the app is off screen is the background-import scenario's.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 35 "auto-import"

# Android only on a phone, for now. Putting a photo into the simulator's library is straightforward (`simctl addmedia`), but there is no
# supported way to take one out again, and a scenario that leaves a photo behind poisons every run after it, including other suites
# sharing the simulator. Skipping is said out loud rather than passing quietly, because a test that reports success without running is
# worse than one that is missing.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: automatic import on a phone is covered on Android only. The iOS simulator has no supported way to remove a seeded photo, so this scenario would leave one behind for every run after it."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

case "$PLATFORM" in
    android)
        # The photos put into the device library, named so a parallel run cannot collide with them. The second is declared here so the
        # exit trap can clean it up whether or not the scenario got that far.
        PHOTO_NAME="psphere-auto-import-$$.jpeg"
        SECOND_PHOTO_NAME="psphere-auto-import-second-$$.png"

        # The album this scenario's photos go in, which is a directory of its own: MediaStore files an item under the directory it sits
        # in, so a directory of our own is an album of our own.
        #
        # That is what makes this scenario run on a real phone as well as an emulator. Switching automatic import on watches the whole
        # photo library, and a phone's library is somebody's photo collection. The scenario would then wait for "Import: 1 imported"
        # while the app took in thousands, and never see it. Pointing automatic import at this album alone means the only photos it can
        # take in are the ones this scenario put there, on any device.
        TEST_ALBUM_DIR="/sdcard/DCIM/psphere-auto-import-$$"

        # The gap between passes, seeded short so the scenario is not waiting out the thirty second default several times over.
        PASS_GAP_MS=5000

        #
        # Waits for the hash cache file the imports should have written into the app's sandbox.
        #
        # It lands under a directory named for a hash of the database path, in a hash-cache directory, as hash-cache-x.dat, inside the
        # hidden cache folder of the app's own files directory rather than anywhere temporary, which is what lets it survive the app being
        # killed and started again. The app makes its own database here, so the hashed directory name is not known to the scenario and the
        # whole tree is listed (hidden folders included, hence -a) rather than the file named. `ls -R` is used instead of a glob because the
        # shell `adb shell` gives us runs as the shell user, which cannot read the app's private storage, so a pattern would come back
        # unexpanded.
        #
        # Both the directory and the file are looked for, so a cache written to the sandbox root, or anywhere else the layout might
        # drift to, does not read as a pass. It is polled rather than read once because the save happens as the import finishes, which
        # is around the same moment as the line the scenario waited for.
        #
        wait_for_hash_cache() {
            local ticks=30
            local listing
            while [ "$ticks" -gt 0 ]; do
                listing="$(photosphere_adb shell run-as "$ANDROID_APP_ID" ls -aR files 2>/dev/null | tr -d '\r')"
                if echo "$listing" | grep -q "/hash-cache:" && echo "$listing" | grep -q "hash-cache-x.dat"; then
                    return 0
                fi
                sleep 1
                ticks=$((ticks - 1))
            done
            return 1
        }

        # Removes the photos from the device library however the scenario ends, so the next run starts clean and a failed run does not
        # leave a photo behind for the one after it to find.
        on_exit() {
            local exit_code=$?
            android_remove_media "$PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true
            android_remove_media "$SECOND_PHOTO_NAME" "$TEST_ALBUM_DIR" 2>/dev/null || true

            # The album directory goes too, so a phone is left as it was found. The files go first and the directory second, because
            # rmdir refuses a directory with anything in it. This is a plain file delete and an empty-directory removal, never a
            # recursive one.
            photosphere_adb shell "rm -f $TEST_ALBUM_DIR/*" >/dev/null 2>&1 || true
            photosphere_adb shell "rmdir $TEST_ALBUM_DIR" >/dev/null 2>&1 || true

            cleanup_apps "$TMP_DIR"
            return $exit_code
        }
        trap on_exit EXIT

        # Wipe everything the app has stored on the device, so this starts with no databases, no settings and no default database.
        # Automatic import creating its own is part of what is under test.
        android_reset_app_state || exit 1

        # Sweep up anything a previous run of this scenario left behind. A run killed outright never reaches its exit trap, and a photo
        # it left would be imported by this one and throw its counts out. The files go first and the now-empty directories second,
        # because a row removed while its file remains is put back by the next scan of the volume.
        photosphere_adb shell "rm -f /sdcard/DCIM/psphere-auto-import-*/*" >/dev/null 2>&1 || true
        photosphere_adb shell "rmdir /sdcard/DCIM/psphere-auto-import-*" >/dev/null 2>&1 || true
        android_remove_media_matching "psphere-auto-import-" || true

        # Put the photo into the device photo library before the app starts, so it is part of the library the backfill walks rather
        # than something that arrives mid-run. Into this scenario's own album, which is what automatic import is pointed at below.
        android_seed_media "$REPO_DIR/test/multiple-files/test-1.jpeg" "$PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

        # The album exists now that something is in it, so MediaStore can be asked for its id.
        TEST_ALBUM_ID="$(android_media_album_id "$PHOTO_NAME")"
        if [ -z "$TEST_ALBUM_ID" ]; then
            log_error "MediaStore did not file $PHOTO_NAME under an album, so automatic import cannot be pointed at one."
            log_error "MediaStore row: $(android_media_store_row "$PHOTO_NAME" || echo "none")"
            exit 1
        fi
        log_info "This scenario's photos are in album $TEST_ALBUM_ID ($TEST_ALBUM_DIR)"

        # Automatic import is switched OFF here and pointed at that album. Switching it ON is what the scenario does through the
        # settings card below, which is the only thing the user does; the card reads these settings and writes back what it read with
        # the switch flipped, so the album survives. No default database path is seeded, because the app creating its own is part of
        # what is under test.
        android_seed_auto_import_config "false" "" "$PASS_GAP_MS" "$TEST_ALBUM_ID" || exit 1

        # Grant the photo permission from outside the app. The system dialog cannot be tapped by a script, and the app's own request
        # resolves straight away once the permission is already held.
        android_grant_media_permission || exit 1

        # And the notification permission, for the same reason. Switching automatic import on starts a foreground service, which the
        # platform requires to post an ongoing notification, so the app asks for this one too at that moment.
        android_grant_notification_permission || exit 1

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # Switch automatic import on through the settings card, which is the only thing the user does.
        click_sidebar_item "$APP_PORT" configuration || exit 1
        wait_for_log "$TMP_DIR" "Automatic import settings loaded"

        send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

        # The app hands the loop to the native side, which is where automatic import runs. The database is created by the first pass
        # rather than by the page, so there is no line here saying so: what the app knows is that it asked for the loop to start, and
        # the import below is the proof it did.
        wait_for_log "$TMP_DIR" "Starting automatic import." || exit 1

        # The photo has to actually arrive. This is the line the task slot deadlock never reached: the loop would report zeros forever
        # because the import it queued could not get a slot.
        #
        # Nothing is waited for between "Starting automatic import." and this. A wait for "Database opened: photosphere-default" would
        # be wrong: the making is ordered, but the two log lines are not. The database is opened by the page when it notices, and the
        # import is done by the native pass, so on a fast run the import line is written first. wait_for_log starts from wherever the
        # last wait left its cursor, so waiting for the open first would move the cursor past the import line and then time out waiting
        # for a line that had already gone by.
        #
        # The database being opened for the user is still asserted, by the photo count below, which is only rendered while a database
        # is open.
        wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

        # The photo has to be in the database the app made, not merely reported as imported, and the count in the navbar says both
        # things at once: it is only rendered while a database is open, and the number is what that database holds. Asserted by value
        # rather than by a log line so it does not depend on where the app had got to when the photo landed.
        wait_for_value_matching "$APP_PORT" "database-photo-count" "^1 photos$" 120

        send_command "$APP_PORT" navigate '{"page":"/import"}' || exit 1
        wait_for_log "$TMP_DIR" "Import page ready" || exit 1

        # A second photo, put into the library while the app is running, has to be noticed and imported on its own. That is the fast
        # lane rather than the backfill, and it is the whole point of the feature: a photo the user has just taken should appear
        # without them doing anything.
        #
        # It also fills the Import page's panel, which only shows what it has been told while it is on screen. The panel is the shared
        # one the desktop uses and it reads task events, so this is what proves the progress of an import running in the background
        # still reaches the interface.
        android_seed_media "$REPO_DIR/test/multiple-files/test-2.png" "$SECOND_PHOTO_NAME" "$TEST_ALBUM_DIR" || exit 1

        # The panel appears on the first progress event it is told about, which is the one sent as the batch is handed over, so it is
        # waited for before the count that follows it. Waiting the other way round moves the log cursor past this line and then times
        # out on it.
        wait_for_log "$TMP_DIR" "Import progress shown" 180 || exit 1

        # One imported, again, rather than two. An import reads its sources to the end and stops, and the app starts another a short
        # while later, so every run counts only what it did: the run that takes in this second photo reports one, exactly as the run
        # that took in the first one did. That both photos are in the database is proven below, by the gallery holding two.
        wait_for_log "$TMP_DIR" "Import: 1 imported" 180 || exit 1

        # Two real imports have now run, so the hash cache has to hold something. Nothing about a cache that was never written looks
        # wrong from outside, and every run would re-export and re-hash every photo it had already imported, which on a real library
        # is about an hour of work per run instead of a second.
        if ! wait_for_hash_cache; then
            log_error "The hash cache was never written: no hash-cache/hash-cache-x.dat anywhere under files/ after two imports. Every import will re-hash every photo it has already imported."
            exit 1
        fi
        log_info "Hash cache written to the app sandbox"

        # The second photo has to land in the gallery without the database being reopened, which is what the arrival messages are for.
        # A photo that only shows up after a restart is not a photo the user saw arrive.
        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets" 60 || exit 1

        # Restart the app and let automatic import run again over the same two photos.
        #
        # This is the whole point of the cache having a home that outlives the process. Automatic import is already switched on and the
        # setting is stored on the device, so the relaunched app starts its own pass with no help from the scenario.
        stop_app "$APP_PORT" "$TMP_DIR"
        reset_log_cursor "$TMP_DIR"
        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # Both photos recognised before they were opened at all, and neither imported again. That is what costs nothing: an item
        # answered before opening is never copied out of the photo library and never hashed, which on a real library is a full copy and
        # a full hash of every photo already imported, every single run.
        #
        # Matched as one substring of the progress line so the figures have to agree in one pass rather than being read from different
        # ones: two already there, both of them answered without opening a file.
        #
        # Waited for generously because the relaunched app may already have run a pass before the page subscribed to task events,
        # and the next one is a pause away.
        wait_for_log "$TMP_DIR" "Import: 0 imported, 2 already there, 0 failed, 2 recognised before opening." 180 || exit 1
        log_info "The restarted app recognised both photos without copying or hashing either"

        check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1
        ;;
    *)
        CONFIG_YAML="$TMP_DIR/config/config.yaml"
        WATCH_DIR="$TMP_DIR/watched-photos"

        trap 'cleanup_apps "$TMP_DIR"' EXIT

        #
        # Prints the indented body of one top-level section of a YAML config file.
        #
        # The settings are grouped by feature now, and `enabled` appears under both `auto_import` and `sync`, so a match against the
        # whole file cannot say which feature it found.
        #
        # The range runs from the section's own line to the next line starting in column one, with both delimiters dropped, so what is
        # left is the section's keys.
        # Usage: config_section <file> <section-name>
        #
        config_section() {
            local file="$1"
            local section="$2"
            sed -n "/^${section}:/,/^[^[:space:]]/{ /^${section}:/d; /^[^[:space:]]/d; p; }" "$file"
        }

        #
        # Polls one section of the config file until it contains a line matching the given extended-regex pattern.
        # Usage: wait_for_config <file> <section-name> <ere-pattern>
        #
        wait_for_config() {
            local file="$1"
            local section="$2"
            local pattern="$3"
            local elapsed=0
            while [ "$elapsed" -lt 30 ]; do
                if [ -f "$file" ] && config_section "$file" "$section" | grep -Eq "$pattern"; then
                    return 0
                fi
                sleep 1
                elapsed=$((elapsed + 1))
            done
            log_error "Timed out waiting for pattern '$pattern' in the $section section of $file"
            [ -f "$file" ] && cat "$file"
            exit 1
        }

        #
        # Waits until the default database holds at least the given number of originals.
        #
        wait_for_asset_count() {
            local expected="$1"
            local elapsed=0
            while [ "$elapsed" -lt 90 ]; do
                local actual
                actual=$(ls -1 "$DEFAULT_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
                if [ "$actual" -ge "$expected" ]; then
                    log_success "The default database holds $actual original(s)"
                    return 0
                fi
                sleep 1
                elapsed=$((elapsed + 1))
            done
            log_error "The default database never reached $expected original(s)"
            ls -la "$DEFAULT_DB_DIR" 2>/dev/null || true
            exit 1
        }

        mkdir -p "$WATCH_DIR"

        # The folder to watch is written before the app starts, so switching automatic import on has somewhere to look that this
        # scenario controls rather than the machine's own photo folders.
        mkdir -p "$TMP_DIR/config"
        cat > "$CONFIG_YAML" <<YAMLEOF
auto_import:
  sources:
    - type: folder
      path: "$WATCH_DIR"
      recurse: true
YAMLEOF

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        # --- 1. Switching automatic import on creates the default database. ---

        click_sidebar_item "$APP_PORT" configuration || exit 1
        wait_for_value "$APP_PORT" "configuration-dialog" "Automatic import"
        log_success "The automatic import card is on the configuration dialog"

        send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

        # The main process reacts to the config write before the page logs its own event, and wait_for_log only ever looks forward from
        # the last line it matched, so these are waited for in the order they are actually written.
        wait_for_log "$TMP_DIR" "Creating the default photo database"
        wait_for_log "$TMP_DIR" "Starting automatic import into"
        wait_for_log "$TMP_DIR" "Automatic import enabled"

        wait_for_config "$CONFIG_YAML" "auto_import" "^[[:space:]]+enabled:[[:space:]]*true"
        wait_for_config "$CONFIG_YAML" "auto_import" "default_database_path"

        # The default database lives under the application data directory, which is inside this scenario's own directory on every
        # desktop platform, so it is found there. The config file names it, but as a folded scalar that can run over two lines, which
        # a search for the folder it is made in does not have to read.
        DEFAULT_DB_DIR="$(find "$TMP_DIR" -type d -name "photosphere-default" -print -quit)"
        if [ -z "$DEFAULT_DB_DIR" ]; then
            log_error "No default database folder was made under $TMP_DIR"
            cat "$CONFIG_YAML"
            exit 1
        fi

        # The database that was just made is opened for the user, without this scenario opening it. The count in the navbar is only
        # rendered while a database is open, so its being there at all is the assertion; the number is whatever has landed by the time
        # it is read, which at this point is usually none.
        wait_for_value_matching "$APP_PORT" "database-photo-count" "^[0-9]+ photos$" 60
        log_success "The default database was opened without being asked for"

        if [ ! -f "$DEFAULT_DB_DIR/.db/files.dat" ]; then
            log_error "The default database was not created at $DEFAULT_DB_DIR"
            ls -la "$DEFAULT_DB_DIR" 2>/dev/null || true
            exit 1
        fi
        log_success "The default private database was created"

        # --- 2. It is listed, and marked as the default. ---

        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"
        wait_for_value "$APP_PORT" "database-default-badge-0" "Default"
        log_success "The default database is listed and badged as the default"

        # --- 3. A file appearing in the watched folder is imported on its own. ---

        cp "$REPO_DIR/test/test.png" "$WATCH_DIR/arrived.png"
        log_info "Dropped a photo into the watched folder"

        wait_for_asset_count 1

        # --- 4. The cleanup button deletes the source files the database already holds. ---

        # This used to be a toggle, with automatic import deleting each file as it confirmed it. On a phone every deletion raises a
        # system confirmation, so that asked the user once per handful of photos. It is a button now: it counts what could go, and
        # deletes it when pressed a second time.

        cp "$REPO_DIR/test/test.jpg" "$WATCH_DIR/cleaned-up.jpg"
        log_info "Dropped a second photo"

        wait_for_asset_count 2

        click_sidebar_item "$APP_PORT" configuration || exit 1
        wait_for_value "$APP_PORT" "configuration-dialog" "Automatic import"

        # The first press counts, and says what it found rather than deleting anything.
        #
        # Pressed until it finds something rather than once. The button can only offer what the import has written to the hash cache,
        # which it does once it has nothing left to import, and a press a fraction of a second after the photo landed can beat that. A
        # user pressing it again would see the same thing; this is that, with a limit so a button that never finds anything still fails.
        #
        # What a press found is read from the button's label, which is the state the next press acts on: it says "Delete" once a count
        # has found something. The page logs "Source cleanup counted" before it has drawn the result, so reading the message under the
        # button as soon as the line appears can see the screen as it was before the count, and a second press made on that reading
        # would delete the files instead of counting them. The label is waited for, so a press is only ever made on a screen that has
        # caught up with the last one.
        COUNT_ATTEMPTS=0
        while true; do
            send_command "$APP_PORT" click '{"dataId":"auto-import-cleanup-button"}' || exit 1
            wait_for_log "$TMP_DIR" "Source cleanup counted"
            COUNT_FOUND=false
            for _look in $(seq 1 20); do
                if read_value "$APP_PORT" "auto-import-cleanup-button" | grep -q "^Delete "; then
                    COUNT_FOUND=true
                    break
                fi
                sleep "$WAIT_POLL_INTERVAL"
            done
            if [ "$COUNT_FOUND" = "true" ]; then
                break
            fi
            COUNT_ATTEMPTS=$((COUNT_ATTEMPTS + 1))
            if [ "$COUNT_ATTEMPTS" -ge 30 ]; then
                log_error "The cleanup button never offered anything to delete. It said: $(read_value "$APP_PORT" "auto-import-cleanup-message")"
                exit 1
            fi
            sleep 1
        done
        wait_for_value "$APP_PORT" "auto-import-cleanup-message" "can be deleted"
        if [ ! -e "$WATCH_DIR/cleaned-up.jpg" ]; then
            log_error "Counting deleted the source file, when it should only have counted it"
            exit 1
        fi
        log_success "Counting deleted nothing"

        # The next press deletes what was counted, and each press after it deletes whatever has become deletable since: a photo only
        # becomes deletable once the import has written its hash down and the database index carries it, which is a moment behind the
        # photo landing.
        DELETE_ATTEMPTS=0
        while [ -e "$WATCH_DIR/cleaned-up.jpg" ] || [ -e "$WATCH_DIR/arrived.png" ]; do
            send_command "$APP_PORT" click '{"dataId":"auto-import-cleanup-button"}' || exit 1
            wait_for_log "$TMP_DIR" "Source cleanup"
            DELETE_ATTEMPTS=$((DELETE_ATTEMPTS + 1))
            if [ "$DELETE_ATTEMPTS" -ge 40 ]; then
                log_error "The cleanup button never deleted the photos the database holds"
                ls -la "$WATCH_DIR"
                exit 1
            fi
            sleep 1
        done
        log_success "The source files the database already held were deleted"

        # --- What was imported is remembered, and survives closing the app. ---

        # The record is what lets a user ask what came in. It is written by the import itself, so it is already on disk here; the point
        # of reading it after a restart is that it is not merely in memory.
        #
        # The record's path carries a hash of the database path, so this script does not build it: a copy of that derivation here
        # would go stale silently the moment the real one changed. It searches this scenario's directory instead, which holds the
        # machine's cache directory of this run and nothing of any other run.
        RECORD_FILE=""
        for attempt in $(seq 1 60); do
            RECORD_FILE="$(find "$TMP_DIR" -name "imports.dat" -not -path "$DEFAULT_DB_DIR/*" -print -quit 2>/dev/null)"
            if [ -n "$RECORD_FILE" ]; then
                break
            fi
            sleep 1
        done

        if [ -z "$RECORD_FILE" ]; then
            log_error "The desktop app wrote no import record under $TMP_DIR"
            find "$TMP_DIR" -type f -not -path "$DEFAULT_DB_DIR/*" 2>/dev/null
            exit 1
        fi
        log_success "The imports were recorded at $RECORD_FILE"

        if ! grep -q '"source":"automatic"' "$RECORD_FILE"; then
            log_error "Photos brought in by automatic import were not badged automatic in $RECORD_FILE"
            exit 1
        fi
        log_success "The automatic imports are badged automatic"

        # The record belongs to the machine, not the database. Nothing may appear inside the database.
        RECORD_INSIDE_DATABASE="$(find "$DEFAULT_DB_DIR" -name "imports.dat" -print -quit 2>/dev/null)"
        if [ -n "$RECORD_INSIDE_DATABASE" ]; then
            log_error "The desktop app wrote an import record inside the database at $RECORD_INSIDE_DATABASE. It belongs on this machine: inside a database, several machines overwrite each other's."
            exit 1
        fi
        log_success "Nothing was written inside the database"

        check_no_errors "$TMP_DIR"

        stop_app "$APP_PORT" "$TMP_DIR"

        # --- Reopen, and the Import page shows what this database took in before. ---

        # The relaunched app starts a fresh app.log, so the cursor from the first run points past the end of it and every wait below
        # would time out on a line that is there.
        reset_log_cursor "$TMP_DIR"

        start_app "$TMP_DIR"
        wait_for_ready "$APP_PORT"

        click_sidebar_item "$APP_PORT" open-database || exit 1
        wait_for_log "$TMP_DIR" "Open database dialog opened"
        send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
        wait_for_log "$TMP_DIR" "Database opened"

        send_command "$APP_PORT" navigate '{"page":"/import"}' || exit 1
        wait_for_log "$TMP_DIR" "Import page ready"

        # The badge is the proof: this row came from the record on disk, not from an import that happened while the page was open,
        # because no import has happened since the app started.
        wait_for_value "$APP_PORT" "import-source-automatic" "Automatic"
        log_success "Reopening the database shows what it imported before"

        check_no_errors "$TMP_DIR"
        ;;
esac

log_success "Test 35 passed: auto-import"
