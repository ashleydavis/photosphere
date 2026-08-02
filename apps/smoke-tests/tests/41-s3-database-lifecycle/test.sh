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
# The answer, as of writing, is that it does not get that far. This test FAILS at step 2 and is left
# failing on purpose. Creating the database reports:
#
#   Create database error:
#   Error: create-database task did not succeed: Failed to list files in
#          photosphere-smoke-test/mobile-lifecycle: Region is missing
#
# "Region is missing" is the AWS SDK saying it was constructed with no credentials object at all, so
# createDatabaseHandler (packages/node-api/src/lib/create-database.worker.ts line 27) got back an
# undefined s3Config from resolveStorageCredentials even though the app had just written the database
# entry with its s3-credentials secret ("Database entry added" is logged immediately before the
# error) and the secret carries region us-east-1. The same flow works on desktop, which test
# 26-s3-database-lifecycle covers and which passes. Why the lookup comes back empty inside the
# embedded engine has NOT been established, so no cause is claimed here.
#
# The native PathSandbox restricts filesystem paths to the app's storage root. An s3: path is not a
# filesystem path and branches earlier in createStorage, so the sandbox is not implicated by the error
# above; it is mentioned only because it was the other candidate before the run.
#
# The path is written in the plain `s3:bucket/prefix` form. The app's own S3 browser produces
# `s3:bucket:/prefix`, and nothing in the storage layer understands the `bucket:` segment (see
# apps/cli/smoke-tests/72-s3-paths, whose final section is left failing on that), so using the working
# form here keeps this test about the mobile lifecycle.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 41 "s3-database-lifecycle"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"
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
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"
log_success "The database was created on S3 from the device"

# --- 3. Open it and import two images. ---

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

# Stage the picked paths, then click the picker button so pickFiles resolves with them and the
# import-assets task runs, writing every asset it produces into the bucket from the embedded engine.
send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/test-1.jpeg\",\".import-tmp/test-2.png\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "2 assets imported"

# --- 4. The gallery reads the assets back out of the bucket. ---

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"
log_success "The imported assets are shown in the gallery"

# Thumbnail fetches for freshly imported assets go through the asset-serving layer; ignore only those,
# exactly as test 4 does.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 41 passed: s3-database-lifecycle"
