#!/bin/bash

# Mobile counterpart of desktop 26-s3-database-lifecycle. Creates a database on S3 from the device,
# imports two images into it, and reads it back, against a real S3 server (a local MinIO on the host).
#
# This is the highest-value S3 test in the suite. mobile-worker-entry.ts registers create-database,
# import-assets, save-asset, load-assets, get-database-summary, sync-database and prefetch-database,
# and every one of them reaches storage through openStorage. None of them has ever run against an s3:
# path inside QuickJS (Android) or JavaScriptCore (iOS). The only S3 call the embedded engine has ever
# made under test is the ListObjectsV2 behind the list-s3-dirs task, which test 40 covers. Whether the
# AWS SDK's GetObject and PutObject work in the embedded engine is what this answers.
#
# The server runs on the host, so the endpoint uses the address the device reaches the host at
# (192.168.55.1 on a bridged emulator, 10.0.2.2 under NAT, loopback on the iOS simulator), never
# "localhost", which on a device means the device itself.
#
# The answer is that they work. GetObject and PutObject both run in the embedded engine, and this
# test passes end to end.
#
# It is worth knowing what it does not tell you quickly, because the failure mode is misleading. The
# worker logs to logcat and not to app.log, so when a step is slow app.log simply stops, and the test
# reports a timeout against the last thing it was waiting for. That reads as a hang and is not one:
# see the note on the create step below.
#
# The path is written in the plain `s3:bucket/prefix` form. The app's own S3 browser produces
# `s3:bucket:/prefix`, and nothing in the storage layer understands the `bucket:` segment (see
# apps/cli/smoke-tests/72-s3-paths, whose final section is left failing on that), so using the working
# form here keeps this test about the mobile lifecycle.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 41 "s3-database-lifecycle"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-lifecycle"

# Stage the two fixture images so only they (not the large archive/video siblings) are seeded.
IMAGES_DIR="$REPO_DIR/test/multiple-files"
STAGE_DIR="$TMP_DIR/import-images"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running. The
# emulator's stop is safe to call when nothing was started, so it goes in unconditionally.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$STAGE_DIR"
cp "$IMAGES_DIR/test-1.jpeg" "$IMAGES_DIR/test-2.png" "$STAGE_DIR/"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/mobile-lifecycle"
log_info "Database path: $S3_DB_PATH"

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the two images into the sandbox import temp directory, which is where the picked paths point.
"${PLATFORM}_seed_database" "$STAGE_DIR" ".import-tmp"

# --- 1. Store the S3 credentials through the app's own Add Secret dialog. ---

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

# --- 2. Create the database on S3 through the Create Database dialog. ---

send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}" || exit 1

send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}' || exit 1

# The S3 Credentials row only renders once the type is S3, so wait for it before clicking.
wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
send_command "$APP_PORT" click '{"dataId":"select-s3-button"}' || exit 1
# Wait for the secret list to mount before picking from it. Clicking straight through leaves the
# chosen secret as "None selected" when the device is slow, because the click lands before the modal
# renders its buttons. The desktop lifecycle test waits on the same line for the same reason.
wait_for_log "$TMP_DIR" "Select secret modal ready"
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1

# Creating a database on S3 is given longer than the 120 second default, because every step of it is
# a round trip to the host and on a NAT-only emulator those are slow enough to matter.
#
# This is what the test was failing on in CI, and the failure read as a hang rather than as slowness:
# app.log stopped at "Database entry added" and nothing followed, because the worker logs to logcat
# and not to app.log. The logcat from a failing run says otherwise. The create-database task was
# still opening sockets at 1.8 a second, 218 of them, right up to 03:04:09.512, and the test gave up
# at 03:04:10. It was not stuck, it had not errored, and it had not finished either: it was still
# working when it was killed. On the bridged emulators used locally the whole test takes 24 seconds.
S3_CREATE_TIMEOUT=300
wait_for_log "$TMP_DIR" "Database created" "$S3_CREATE_TIMEOUT"
log_success "The database was created on S3 from the device"

# --- 3. Import two images into it. ---

# Creating the database opens it, so there is no open step here. Opening it a second time would
# cancel the task source the first open established, and the engine pool remembers a cancelled
# source, so the load queued against it is dropped and never completes. Test 36 documents the same
# trap for the replicate flow.
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

# Creating the database leaves the secrets page on screen, and the Import button lives on the
# gallery, so navigate there before reaching for it.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

# Stage the picked paths, then click the picker button so pickFiles resolves with them and the
# import-assets task runs, writing every asset it produces into the bucket from the embedded engine.
send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test-1.jpeg\",\".import-tmp/test-2.png\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1

# Given the same room the create step above is given, and for the same reason: every asset this
# writes is a round trip to the host, and on the NAT-only emulator the workflow runs they are slow.
# Locally, on a bridged emulator, the whole test takes 20 seconds.
#
# Twice the default budget was still close enough to what the work takes to make this a coin flip
# rather than a check. In the release run of 2026-08-31 the step read as a hang rather than as
# slowness, because app.log stopped at the click on import-files-button: the logcat kept by
# scripts/android-smoke-tests-ci.sh shows the import-assets task added at 10:21:18.814, the two
# hashes finished at 10:22:57.9, both save-asset tasks succeeded at 10:23:06.4 (8.5s each, 2.6s of
# that uploading), and the worker still emitting task messages at 10:23:19.4 when the wait ran out
# and the app was force-stopped at 10:23:21.9. Both assets were in the artifact's bucket with their
# thumb and display renditions and nothing had errored: the import simply had seconds left to run.
# On 2026-09-01 03:33 it passed with the import taking 135 seconds, and two runs later the same step,
# on a branch that had done nothing to it, timed out at 124.
S3_IMPORT_TIMEOUT=300
wait_for_log "$TMP_DIR" "2 assets imported" "$S3_IMPORT_TIMEOUT"

# --- 4. The gallery reads the assets back out of the bucket. ---

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The imported assets are shown in the gallery"

# Thumbnail fetches for freshly imported assets go through the asset-serving layer; ignore only those,
# exactly as test 4 does.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 41 passed: s3-database-lifecycle"
