#!/bin/bash

# Sync and prefetch on device with the ORIGIN on S3 rather than a second on-device database.
#
# Tests 34 (sync) and 36 (prefetch) both cover these handlers with a local origin, which is
# deliberately the easy case: everything stays inside the app's storage sandbox and no network call is
# made. This is the same two handlers with the origin in a bucket, so sync-database and
# prefetch-database have to read from S3 through the embedded JS engine.
#
# The origin database is built on the host with the CLI and lives only in the bucket. The on-device
# database is a partial replica of it whose .db/config.json names the S3 path as its origin, seeded
# from the host: the worker's sync handler reads the origin out of the database's own config, not out
# of the app's database list, so it has to be baked into the fixture before it is pushed to the device.
#
# The server runs on the host, so the endpoint uses the address the device reaches the host at, never
# "localhost", which on a device means the device itself.
#
# Read 41-s3-database-lifecycle before this one: it establishes that the S3 credential lookup comes
# back empty inside the embedded engine, so this test is expected to fail for the same underlying
# reason. It is written and run anyway, because when that is fixed these two handlers still have to be
# proven over S3 and this is the test that does it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 42 "s3-sync-prefetch"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"
S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-replica"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_ORIGIN_PATH="s3:$S3_EMULATOR_BUCKET/mobile-origin"
log_info "Origin database on S3: $S3_ORIGIN_PATH"

# --- 1. Build the origin database in the bucket, from the host. ---

# Isolate the host CLI's config and vault. Without this it reads the developer's real ones, and
# resolveStorageCredentials prefers a databases.json entry's vault secret over the AWS_* variables
# below, so a same-named entry on the machine silently points these commands at a different server.
export PHOTOSPHERE_CONFIG_DIR="$TMP_DIR/host-config"
export PHOTOSPHERE_VAULT_DIR="$TMP_DIR/host-vault"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# The CLI reads these when the database entry names no vault secret, which is the case for a path used
# directly on the command line. The host reaches the emulator on loopback; only the device needs the
# host address.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

log_info "Creating the origin database in the bucket with the CLI"
( cd "$REPO_DIR/apps/cli" && bun run start -- init --db "$S3_ORIGIN_PATH" --yes ) || exit 1
( cd "$REPO_DIR/apps/cli" && bun run start -- add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_ORIGIN_PATH" --yes ) || exit 1

# A partial replica on the host, which becomes the on-device database. A partial replica copies the
# merkle trees but no thumbnails, which is exactly what prefetch-database exists to fill in.
LOCAL_REPLICA="$TMP_DIR/$DB_NAME"
( cd "$REPO_DIR/apps/cli" && bun run start -- replicate --db "$S3_ORIGIN_PATH" --dest "$LOCAL_REPLICA" --partial --yes ) || exit 1

# Point the replica at the S3 origin. The sync and prefetch handlers both read this file.
printf '{"origin":"%s"}\n' "$S3_ORIGIN_PATH" > "$LOCAL_REPLICA/.db/config.json"

# --- 2. Put it on the device, with the credentials the app will need. ---

# Wipe everything the app has stored on the device so this test starts from a known state.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

"${PLATFORM}_seed_database" "$LOCAL_REPLICA" "$DB_NAME"
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Load assets task completed"

# --- 3. Prefetch pulls the missing thumbnails down out of the bucket. ---

# Opening a partial replica fire-and-forget queues a prefetch-database task. Its effect on device
# storage is the assertion: the thumb directory, absent from a partial replica, appears once the
# prefetch has copied thumbnails out of S3.
if ! "${PLATFORM}_wait_for_file" "$DB_NAME/thumb"; then
    log_error "Prefetch from an S3 origin never produced $DB_NAME/thumb on the device"
    exit 1
fi
log_success "Prefetch pulled thumbnails down from the S3 origin"

# --- 4. An edit triggers a sync against the S3 origin, start to finish. ---

send_command "$APP_PORT" notify-database-edited '{}' || exit 1

# Observed from the append-only app log rather than by polling the navbar, for the reason test 34
# gives: a fast sync can finish inside one poll interval and polling for the transient state is a race.
wait_for_log "$TMP_DIR" "Sync started"
wait_for_log "$TMP_DIR" "Sync completed"
log_success "A sync against the S3 origin ran start to finish"

wait_for_value "$APP_PORT" "navbar-sync-state" "idle" 60

# Thumbnail fetches go through the asset-serving layer; ignore only those, as tests 34 and 36 do.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 42 passed: s3-sync-prefetch"
