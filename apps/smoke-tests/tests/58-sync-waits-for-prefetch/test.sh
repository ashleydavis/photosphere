#!/bin/bash

# The periodic sync waits while a prefetch is filling a replica in, and does not wait for one that is
# stuck.
#
# A sync that overlaps a working prefetch does the same work slowly and gets in its own way. Measured
# on a Pixel 6: reaching the origin's merkle tree took 81.5 seconds during a pass that overlapped a
# prefetch, against 97 milliseconds when the phone was idle, and the record merge in that pass took 15
# minutes because it was pulling the metadata shards down one at a time through the lazy storage, which
# is the same set of files the prefetch was fetching.
#
# The hazard is the opposite mistake, and it is worse: a sync that waits for a prefetch that can never
# finish is a phone that has silently stopped backing up, which is the exact failure this whole piece
# of work exists to remove. So the wait is bounded by PROGRESS rather than by completion, and this test
# asserts both halves of that.
#
# It runs in two phases, each with its own app state, because a replica cannot be both stuck and
# filled in:
#
#   1. Stuck. The replica's origin has no credentials on the device, so every read of it fails, the
#      prefetch pass fails, and the driver reports the replica stalled. Syncing must go on being
#      attempted: it will fail too, and that is fine, because what is under test is whether it was
#      allowed to try.
#   2. Working, then finished. The credentials are in place, so the prefetch fetches the origin's
#      thumbnails. Syncing must be refused while that is happening, naming the prefetch, and must run
#      again once the replica is filled in.
#
# Everything is read from logcat, because that is where the native loops say what they are doing and it
# keeps working with the app off screen, which app.log does not.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 58 "sync-waits-for-prefetch"

# Android only, for the same reason 50-background-sync and 57-prefetch-retries are: this asserts on
# loops that run inside a foreground service, and iOS has no such thing. There the loops run while the
# app is foregrounded and otherwise through BGProcessingTasks the system schedules when it chooses, and
# the only way to force one is an lldb command this harness cannot issue on Xcode 14.2. See
# IOS-NOT-COVERED.md beside this file.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: the ordering between the background sync and the background prefetch is covered on Android only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="sync-waits-origin-s3"
DB_NAME="sync-waits-replica"

# How many photos the origin holds. Enough that the prefetch's first pass has real work to do and takes
# meaningfully longer than a sync pass that finds nothing to do, which is what puts the sync's next
# question inside the window where the prefetch has fetched something and not yet confirmed it has
# finished. Small enough that building the origin with the CLI is not the slowest part of the test.
ORIGIN_PHOTO_COUNT=12

# The gap both loops wait between passes. They share it: the prefetch deliberately has no settings of
# its own. Short, so the test does not wait out the five minute default several times over.
PASS_GAP_MS=3000

# How long each phase is given to produce the lines it is waiting for.
PHASE_TIMEOUT_SECONDS=180

# Stop the app AND the S3 emulator, so a failed assertion never leaves a MinIO server running.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR"

#
# True when the foreground service that hosts the loops is running.
#
loops_service_running() {
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"
}

#
# Waits for a line from the service in logcat.
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

#
# Fails when the service has said something it should not have.
# Usage: refute_service_log <pattern> <what>
#
refute_service_log() {
    local pattern="$1"
    local what="$2"

    if adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep -qE "$pattern"; then
        log_error "$what"
        adb logcat -d -s "AutoImportService:*" 2>/dev/null | grep -E "$pattern" | tail -5 || true
        return 1
    fi

    log_success "$what did not happen, as it should not have"
    return 0
}

#
# Brings the app up with the settings currently seeded, and waits for the service.
#
restart_app_and_wait_for_service() {
    adb logcat -c >/dev/null 2>&1 || true
    adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    "${PLATFORM}_launch" "$APP_PORT" || return 1
    wait_for_ready "$APP_PORT" || return 1

    local waited=0
    while [ "$waited" -lt 60 ]; do
        if loops_service_running; then
            log_info "The foreground service is running"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "The foreground service is not running with syncing switched on, so neither loop can run."
    adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | head -30 || true
    return 1
}

# --- 1. The origin database, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/sync-waits-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the origin database with $ORIGIN_PHOTO_COUNT photos in it"
run_cli "$TMP_DIR" init --db "$S3_ORIGIN_PATH" --yes || exit 1

# The same two fixtures over and over under different names, because what matters is the number of
# files the prefetch has to fetch rather than what is in them. Copied rather than re-added from the
# same path, because the import skips a file it has already taken in.
ORIGIN_PHOTOS_DIR="$TMP_DIR/origin-photos"
mkdir -p "$ORIGIN_PHOTOS_DIR"
photo_index=0
while [ "$photo_index" -lt "$ORIGIN_PHOTO_COUNT" ]; do
    if [ $((photo_index % 2)) -eq 0 ]; then
        cp "$REPO_DIR/test/multiple-files/test-1.jpeg" "$ORIGIN_PHOTOS_DIR/photo-$photo_index.jpeg"
    else
        cp "$REPO_DIR/test/multiple-files/test-2.png" "$ORIGIN_PHOTOS_DIR/photo-$photo_index.png"
    fi
    photo_index=$((photo_index + 1))
done

run_cli "$TMP_DIR" add "$ORIGIN_PHOTOS_DIR" --db "$S3_ORIGIN_PATH" --yes || exit 1

# --- 2. The phone's database, which is a partial replica of that origin. ---

LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
run_cli "$TMP_DIR" replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes || exit 1
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

if [ -d "$LOCAL_REPLICA/thumb" ]; then
    log_error "The partial replica already holds a thumb directory, so the prefetch would have nothing to do and neither phase below would mean anything."
    exit 1
fi

# --- 3. Phase one: a stuck prefetch must not stop syncing. ---

"${PLATFORM}_reset_app_state" || exit 1
"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1

# The notification permission, or the app waits for ever on a system dialog no test can tap and no
# service is ever started.
"${PLATFORM}_grant_notification_permission" || exit 1

# The replica alone. Its origin is deliberately NOT registered, so the origin is opened with no
# credentials at all and every read of it fails, which is what makes the prefetch stall.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]" || exit 1
"${PLATFORM}_seed_sync_config" "true" "false" "$PASS_GAP_MS" "$DB_NAME" || exit 1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

# The credentials are added anyway, so phase two only has to change the database list. They are of no
# use to phase one, because nothing names them for the origin's path.
send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

restart_app_and_wait_for_service || exit 1

# The prefetch cannot read the origin, so its pass fails and the driver reports the replica stalled.
wait_for_service_log 'Prefetch step "prefetch-database" (did not succeed|failed)' \
    "The prefetch pass failed, as it must with no credentials for the origin" "$PHASE_TIMEOUT_SECONDS" || exit 1

# And syncing goes on being attempted. This is the assertion the whole ordering rests on: a sync that
# waited here would wait for the life of the app.
wait_for_service_log 'Syncing "' \
    "Syncing was still attempted while the prefetch was stuck" "$PHASE_TIMEOUT_SECONDS" || exit 1

refute_service_log 'a prefetch is still filling this database in' \
    "Holding syncing back for a stuck prefetch" || exit 1

# --- 4. Phase two: a working prefetch does hold syncing back, and then lets it go. ---

# The origin registered with its credentials, which is the one thing that changes. Everything else,
# including the replica and the settings, stays exactly as it was.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"},{\"name\":\"$DB_NAME-origin\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

restart_app_and_wait_for_service || exit 1

# The prefetch now fetches, and the sync asks again every gap. The window where the prefetch has
# fetched something and not yet confirmed there is nothing left is at least one gap wide, so a sync
# question lands inside it.
wait_for_service_log 'a prefetch is still filling this database in' \
    "Syncing was held back while the prefetch was working" "$PHASE_TIMEOUT_SECONDS" || exit 1

# Then the replica is filled in and the prefetch loop ends.
wait_for_service_log 'is filled in; nothing left to fetch' \
    "The prefetch finished filling the replica in" "$PHASE_TIMEOUT_SECONDS" || exit 1

# And syncing is let go of again. Cleared first, so this is a sync that ran AFTER the prefetch
# finished rather than one from before it started.
adb logcat -c >/dev/null 2>&1 || true
wait_for_service_log 'Syncing "' \
    "Syncing ran again once the prefetch had finished" "$PHASE_TIMEOUT_SECONDS" || exit 1

log_success "Test 58 passed: sync-waits-for-prefetch"
