#!/bin/bash

# A partial replica is filled in by the background loop, without the database ever being opened.
#
# Until this loop existed, the only thing that ever queued a prefetch was the end of a load-assets
# run, so a prefetch that failed part way was never tried again and the replica it was filling in
# stayed unfinished. A sync cannot repair that: a sync copies what the difference between two merkle
# trees shows, and a partial replica's tree already matches its origin's, so a missing file is
# invisible to it. Measured on a Pixel 6, a prefetch died 38 minutes in with every thumbnail fetched
# and the database index files missing, and nothing ever started another.
#
# The database is deliberately never opened. Opening one queues a prefetch of its own, which is the
# interactive path and would fill the replica in whether or not the loop worked, so this test asserts
# on a replica nothing has opened: the files can only have arrived through the background loop.
#
# Automatic import is left switched OFF and only syncing is switched on, which is enough to bring the
# foreground service up (test 50 covers that on its own). That keeps the photo library, the album and
# the media permission out of a test that is about neither.
#
# The loop then has to STOP. A loop that kept asking would walk every object at the origin every gap,
# which on a real library is thousands of listings and thousands of local existence checks for nothing,
# and the line it writes when it stops is the only place that decision is visible.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 57 "prefetch-retries"

# Android only, for the same reason 50-background-sync is: this test asserts on a loop that runs
# inside a foreground service, and iOS has no such thing. There the loop runs while the app is
# foregrounded and otherwise through a BGProcessingTask the system schedules when it chooses, and the
# only way to force one is an lldb command against a running app, which this harness cannot issue on
# Xcode 14.2. See IOS-NOT-COVERED.md beside this file.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: the background prefetch loop is covered on Android only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="prefetch-origin-s3"
DB_NAME="prefetch-replica"

# How long the background loop is given to fill the replica in and then stop. The gap between passes
# is seeded at five seconds below, so this is many passes' worth on a slow emulator.
PREFETCH_TIMEOUT_SECONDS=180

# Stop the app AND the S3 emulator, so a failed assertion never leaves a MinIO server running.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR"

#
# True when the foreground service that hosts the loops is running.
#
prefetch_service_running() {
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"
}

#
# Waits for a line from the service in logcat, which is where the loops say what they are doing.
#
# Logcat rather than app.log, because the loops run natively and keep running with the app off screen,
# which is exactly when app.log (written over a socket from the WebView) stops being written.
# Usage: wait_for_service_log <pattern> <what> <timeout-seconds>
#
wait_for_service_log() {
    local pattern="$1"
    local what="$2"
    local timeout="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep -qE "$pattern"; then
            log_success "$what"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "$what: the service never said anything matching /$pattern/ in ${timeout}s"
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tail -40 || true
    return 1
}

# --- 1. The origin database, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/prefetch-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used
# directly on the command line. The host reaches the emulator on loopback; only the device needs the
# host address that start_s3_emulator worked out.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the origin database in the bucket with the CLI"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_ORIGIN_PATH" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/multiple-files/test-2.png" --db "$S3_ORIGIN_PATH" --yes || exit 1

# --- 2. The phone's database, which is a partial replica of that origin. ---

LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
run_cli "$TMP_DIR" replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes || exit 1

# Point the replica at the origin. This is the file plan-prefetch reads to find out there is somewhere
# to fetch from, and the prefetch task reads to find out where.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

# The starting state this test rests on: a partial replica holds the merkle trees and the records and
# none of the thumbnails. Asserted rather than assumed, because a replica that already had them would
# make everything below pass without the loop doing anything at all.
if [ -d "$LOCAL_REPLICA/thumb" ]; then
    log_error "The partial replica already holds a thumb directory, so this test cannot tell whether the background loop fetched anything."
    ls -R "$LOCAL_REPLICA" | head -30
    exit 1
fi
log_info "The partial replica holds no thumbnails, which is what the background loop has to fix"

# --- 3. Put it on the phone, with syncing on and automatic import off. ---

# Wipe everything the app has stored on the device, so this test starts from a known state and, in
# particular, from a state where no database has ever been opened.
"${PLATFORM}_reset_app_state" || exit 1

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1

# The notification permission, from outside the app. The service the loops live in is a foreground
# service, which the platform requires to post an ongoing notification, so the app asks for this
# permission before it starts one. A test cannot tap the system dialog, and without the permission
# already held the app waits on it for ever and no service is ever started: the whole of this test
# then fails on a missing service rather than on anything it is about.
#
# The photo library permission is deliberately NOT granted. Automatic import stays off here, and it is
# the only thing that reads the library.
"${PLATFORM}_grant_notification_permission" || exit 1

# Both databases are registered: the on-device replica and its origin in the bucket. Credentials are
# resolved by exact path, and the prefetch opens the origin by the path recorded in the replica's own
# config, so without an entry for that path the origin is opened with no credentials at all and every
# read of it fails.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"},{\"name\":\"$DB_NAME-origin\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

# The credentials for the bucket, added the way a user adds them. They cannot be seeded: the Android
# secure store is EncryptedSharedPreferences over a Keystore master key, so its contents cannot be
# authored from the host.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# Syncing on, naming the replica, with a short gap so the test is not waiting out the five minute
# default several times over. Automatic import stays off: the service comes up for either feature, and
# leaving the import off keeps the photo library out of this.
"${PLATFORM}_seed_sync_config" "true" "false" "5000" "$DB_NAME" || exit 1

# Restarted because a settings file changed from outside is only read at launch: the app notices its
# own writes, not the harness's.
adb logcat -c >/dev/null 2>&1 || true
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
"${PLATFORM}_launch" "$APP_PORT" || exit 1
wait_for_ready "$APP_PORT"

SERVICE_UP=0
for _ in $(seq 1 60); do
    if prefetch_service_running; then
        SERVICE_UP=1
        break
    fi
    sleep 1
done

if [ "$SERVICE_UP" -ne 1 ]; then
    log_error "The foreground service is not running with syncing switched on, so no background loop can run."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    exit 1
fi
log_info "The foreground service is running"

# --- 4. The loop fills the replica in. ---

wait_for_service_log 'Filling in "' "The background prefetch loop asked for a pass" "$PREFETCH_TIMEOUT_SECONDS" || exit 1

# The assertion this test exists for, made against the device's own disk rather than anything the app
# says: the thumb directory is absent from a partial replica and appears once the loop has fetched
# what the origin holds.
if ! "${PLATFORM}_wait_for_file" "$DB_NAME/thumb"; then
    log_error "The background loop never fetched the origin's thumbnails into the replica on the device."
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tail -40 || true
    exit 1
fi
log_success "The background loop filled the replica in, with nothing having opened the database"

# --- 5. And then stops, rather than walking the origin for ever. ---

wait_for_service_log 'is filled in; nothing left to fetch' "The loop stopped once the replica was complete" "$PREFETCH_TIMEOUT_SECONDS" || exit 1

# --- 6. Nothing opened the database, so the load-assets prefetch cannot be what did this. ---

# Checked last, so a failure above is reported as the failure it is rather than as this one. The app
# log is the record of what the interface did, and opening a database is the one thing there that
# queues a prefetch of its own.
if grep -q "Opening database" "$TMP_DIR/app.log"; then
    log_error "The app opened a database during this test, so the files could have been fetched by the prefetch that load-assets queues rather than by the background loop."
    grep -n "Opening database" "$TMP_DIR/app.log" | head -5
    exit 1
fi
log_success "No database was opened, so only the background loop can have fetched the files"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 57 passed: prefetch-retries"
