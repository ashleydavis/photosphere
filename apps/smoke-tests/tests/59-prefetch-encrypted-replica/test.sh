#!/bin/bash

# The background prefetch loop fills in a partial replica of an ENCRYPTED database.
#
# 57-prefetch-retries covers the same loop against an unencrypted replica, which is the easy case and
# is the only case it covered. Against an encrypted one the loop could not run at all: plan-prefetch
# asked isDatabasePartial whether the replica was partial without handing it any credentials, so the
# merkle tree it reads to answer that was read as the raw ciphertext it is on disk, and every pass
# failed on the serialized checksum. Measured on a Pixel 6 against an encrypted S3 origin, once a
# pass, for as long as the phone was left running:
#
#   E AutoImportService: Could not work out what the background prefetch should do:
#     plan-prefetch failed: Checksum mismatch: expected <the file's last 32 bytes> got <...>
#
# A phone's database is encrypted, so that was the loop not working at all in the case that matters,
# behind a test suite that was green.
#
# This needs the LAN bridge and 57 does not, which is why it is a test of its own rather than 57 made
# encrypted: the encryption key cannot be seeded into the device keychain from the host (Android's
# secure store is EncryptedSharedPreferences over a Keystore master key), so the only way it gets
# there is a real LAN share, and a run declaring it has no bridge would then lose all coverage of the
# loop rather than just this half of it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 59 "prefetch-encrypted-replica"

# Android only, for the reason 57 gives: this asserts on a loop that runs inside a foreground service,
# and iOS has no such thing. See IOS-NOT-COVERED.md beside this file.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: the background prefetch loop is covered on Android only. iOS runs its passes when the system decides, and there is no supported way to make one happen from a test."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

S3_STATE_DIR="$TMP_DIR/s3"
S3_SECRET_NAME="prefetch-enc-s3"
ENC_KEY_NAME="prefetch-enc-key"
ORIGIN_ENTRY_NAME="prefetch-enc-origin"
DB_NAME="prefetch-enc-replica"

# How long the background loop is given to fill the replica in and then stop. The gap between passes
# is seeded at five seconds below, so this is many passes' worth on a slow emulator.
PREFETCH_TIMEOUT_SECONDS=180

# Drawn per run, never hardcoded: the code is the only thing that tells two concurrent shares apart.
PAIRING_CODE="$(allocate_pairing_code)"

# A host-side sender can only reach the device's receiver over the LAN. Checked before the trap is
# armed, so failing here does not run a teardown for an app that never started.
require_lan_bridge

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

#
# Runs a CLI command and fails the test with the CLI's own output when it does not succeed. Every one
# of these sets up state the rest of the test silently depends on.
# Usage: cli_expect_success <description> <cli args...>
#
cli_expect_success() {
    local description="$1"
    shift
    local cli_output
    if ! cli_output="$(run_cli "$TMP_DIR" "$@" 2>&1)"; then
        log_error "$description failed. The CLI said:"
        echo "$cli_output" | sed 's/^/  /'
        exit 1
    fi
}

# --- 1. The encrypted origin database, in a bucket on this machine. ---

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/prefetch-enc-origin"
log_info "Encrypted origin database on S3: $S3_ORIGIN_PATH"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used
# directly on the command line. The host reaches the emulator on loopback; only the device needs the
# host address that start_s3_emulator worked out.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

# jq builds the JSON so the credentials are never hand-quoted. The field names are the ones
# resolveDatabaseSharePayload reads out of the secret.
S3_SECRET_JSON="$(jq -nc \
    --arg region "us-east-1" \
    --arg accessKeyId "$S3_EMULATOR_ACCESS_KEY" \
    --arg secretAccessKey "$S3_EMULATOR_SECRET_KEY" \
    --arg endpoint "$S3_ENDPOINT" \
    '{region: $region, accessKeyId: $accessKeyId, secretAccessKey: $secretAccessKey, endpoint: $endpoint}')"

cli_expect_success "Adding the S3 credentials secret" \
    secrets add --yes --name "$S3_SECRET_NAME" --type s3-credentials --value "$S3_SECRET_JSON"

# --generate-key creates the named key in the vault, so this is what puts the encryption key there for
# the share below to carry. --key takes a vault secret name, not a file path.
cli_expect_success "Initialising the encrypted origin on S3" \
    init --db "$S3_ORIGIN_PATH" --generate-key --key "$ENC_KEY_NAME" --yes

cli_expect_success "Adding the first photo to the origin" \
    add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_ORIGIN_PATH" --key "$ENC_KEY_NAME" --yes
cli_expect_success "Adding the second photo to the origin" \
    add "$REPO_DIR/test/multiple-files/test-2.png" --db "$S3_ORIGIN_PATH" --key "$ENC_KEY_NAME" --yes

# The entry is what the share carries, and it is what names both secrets: the device receives the
# credentials and the key because this entry references them by name.
cli_expect_success "Registering the origin with its credentials and key" \
    dbs add --yes --name "$ORIGIN_ENTRY_NAME" --description "Encrypted S3 origin" --path "$S3_ORIGIN_PATH" \
        --s3-cred "$S3_SECRET_NAME" --encryption-key "$ENC_KEY_NAME"

# --- 2. The phone's database, an encrypted partial replica of that origin. ---

LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
cli_expect_success "Making the encrypted partial replica" \
    replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes \
        --key "$ENC_KEY_NAME" --dest-key "$ENC_KEY_NAME"

# Point the replica at the origin. This is the file plan-prefetch reads to find out there is somewhere
# to fetch from, and the prefetch task reads to find out where.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

# The replica really is encrypted, which is the whole point of this test: the merkle tree the loop has
# to read is one of the encrypted files, and a replica that turned out to be plaintext would make this
# test a second copy of 57.
if ! head -c 4 "$LOCAL_REPLICA/.db/files.dat" | grep -q "PSEN"; then
    log_error "The replica's merkle tree is not encrypted, so this test would not cover what it exists to cover."
    head -c 64 "$LOCAL_REPLICA/.db/files.dat" | od -c | head -4
    exit 1
fi
log_info "The replica's merkle tree is encrypted, so reading it needs the key from the device keychain"

# The starting state the assertions rest on: a partial replica holds the merkle trees and the records
# and none of the thumbnails.
if [ -d "$LOCAL_REPLICA/thumb" ]; then
    log_error "The partial replica already holds a thumb directory, so this test cannot tell whether the background loop fetched anything."
    exit 1
fi
log_info "The partial replica holds no thumbnails, which is what the background loop has to fix"

# --- 3. Put the credentials and the key on the phone, through a real LAN share. ---

# Wipe everything the app has stored on the device, so this test starts from a known state and, in
# particular, from a state where no database has ever been opened.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Receive database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$PAIRING_CODE\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1

# Give the receiver a moment to begin broadcasting before the host starts looking for it, exactly as
# tests 26, 45 and 56 do. The sender's discovery has a 60 second budget, so this is slack, not a race.
sleep 3
log_info "Sending the origin's entry, credentials and encryption key from the host CLI..."
cli_send_expect_success "$TMP_DIR" dbs send --yes --name "$ORIGIN_ENTRY_NAME" --code "$PAIRING_CODE"

wait_for_log "$TMP_DIR" "Database review step"
send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database imported"
send_command "$APP_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1
log_success "The device keychain now holds the bucket's credentials and the database's encryption key"

# --- 4. Put the replica on the phone, with syncing on and automatic import off. ---

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME" || exit 1

# The notification permission, from outside the app. The service the loops live in is a foreground
# service, so the app asks for this before starting one, and a test cannot tap the system dialog.
#
# The photo library permission is deliberately NOT granted: automatic import stays off here and it is
# the only thing that reads the library.
"${PLATFORM}_grant_notification_permission" || exit 1

# Both databases are registered, and the replica's entry names the encryption key the share just put
# in the keychain. Written after the share rather than before, because the share writes this file too
# and would otherwise be overwritten; the secrets it delivered are in the keychain either way, and
# this list references them by the same names.
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\",\"encryptionKey\":\"$ENC_KEY_NAME\"},{\"name\":\"$ORIGIN_ENTRY_NAME\",\"path\":\"$S3_ORIGIN_PATH\",\"s3Key\":\"$S3_SECRET_NAME\",\"encryptionKey\":\"$ENC_KEY_NAME\"}]" || exit 1

# Syncing on, naming the replica, with a short gap so the test is not waiting out the five minute
# default several times over. Automatic import stays off: the service comes up for either feature.
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

# --- 5. The loop works out that it has something to do, which is what was broken. ---

# The failure this test exists for was not a slow prefetch: it was the plan task throwing, so the loop
# asked, failed, waited and asked again for ever. Asserting on the refusal line as well as on the
# files makes a regression say which half broke.
if adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep -q "Could not work out what the background prefetch should do"; then
    log_error "The loop could not decide what to do against an encrypted replica, which is the fault this test exists for."
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep "background prefetch" | head -5
    exit 1
fi

wait_for_service_log 'Filling in "' "The background prefetch loop asked for a pass against the encrypted replica" "$PREFETCH_TIMEOUT_SECONDS" || exit 1

# --- 6. And fills the replica in. ---

if ! "${PLATFORM}_wait_for_file" "$DB_NAME/thumb"; then
    log_error "The background loop never fetched the encrypted origin's thumbnails into the replica on the device."
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tail -40 || true
    exit 1
fi
log_success "The background loop filled the encrypted replica in, with nothing having opened the database"

# --- 7. And then stops, rather than walking the origin for ever. ---

wait_for_service_log 'is filled in; nothing left to fetch' "The loop stopped once the encrypted replica was complete" "$PREFETCH_TIMEOUT_SECONDS" || exit 1

# The loop must never have failed a pass on the way, because a pass that throws reports the replica
# stalled and is what a sync then stops waiting for.
if adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep -qE "Prefetch step .* (failed|did not succeed)"; then
    log_error "A prefetch pass failed against the encrypted replica, even though the replica was eventually filled in."
    adb logcat -d -s "AutoImportService:*" 2>/dev/null | tr -d '\r' | grep "Prefetch step" | head -5
    exit 1
fi

# --- 8. Nothing opened the database, so the load-assets prefetch cannot be what did this. ---

# Checked last, so a failure above is reported as the failure it is rather than as this one.
if grep -q "Opening database" "$TMP_DIR/app.log"; then
    log_error "The app opened a database during this test, so the files could have been fetched by the prefetch that load-assets queues rather than by the background loop."
    grep -n "Opening database" "$TMP_DIR/app.log" | head -5
    exit 1
fi
log_success "No database was opened, so only the background loop can have fetched the files"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 59 passed: prefetch-encrypted-replica"
