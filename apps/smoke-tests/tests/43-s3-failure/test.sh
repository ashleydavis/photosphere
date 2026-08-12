#!/bin/bash

# Mobile counterpart of desktop 28-s3-failure. An S3 database whose bucket has become unreachable must
# surface an error on the device, not an empty gallery.
#
# An empty gallery for an unreachable bucket is indistinguishable from a database with nothing in it,
# so a user looking at one cannot tell that their photos are still there and merely out of reach. That
# is the same class of fault test 40 already guards against for the bucket browser, applied to opening
# a database.
#
# The database is built in the bucket from the host with the CLI and genuinely holds an asset, so the
# empty gallery this test is looking out for would definitely be wrong. The emulator is then stopped
# before the app ever opens it, so nothing on the device can be serving it from a cache.
#
# Read 41-s3-database-lifecycle before this one: it establishes that the S3 credential lookup comes
# back empty inside the embedded engine. A credential failure and an unreachable server both have to
# produce an error rather than an empty gallery, so this test's assertion still means what it says,
# but the error it observes may be the credential one until that is fixed.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 43 "s3-failure"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="s3-unreachable"

trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/mobile-failure"
log_info "Database path: $S3_DB_PATH"

# --- 1. Build a populated database in the bucket, from the host. ---

# Isolate the host CLI's config and vault. Without this it reads the developer's real ones, and
# resolveStorageCredentials prefers a databases.json entry's vault secret over the AWS_* variables
# below, so a same-named entry on the machine silently points these commands at a different server.
export PHOTOSPHERE_CONFIG_DIR="$TMP_DIR/host-config"
export PHOTOSPHERE_VAULT_DIR="$TMP_DIR/host-vault"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# The host reaches the emulator on loopback; only the device needs the host address.
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION="us-east-1"

( cd "$REPO_DIR/apps/cli" && bun run start -- init --db "$S3_DB_PATH" --yes ) || exit 1
( cd "$REPO_DIR/apps/cli" && bun run start -- add "$REPO_DIR/test/multiple-files/test-1.jpeg" --db "$S3_DB_PATH" --yes ) || exit 1
log_success "The bucket holds a database with one asset in it"

# --- 2. Register it on the device, then take the server away. ---

"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY" || exit 1

"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$S3_DB_PATH\",\"s3Key\":\"$SECRET_NAME\"}]" || exit 1

log_info "Stopping the S3 emulator; the bucket is now unreachable from the device"
stop_s3_emulator "$S3_STATE_DIR"

# --- 3. Opening it must report a failure, not an empty gallery. ---

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

# Two outcomes, and the app can only produce one of them for this open.
#
# The failure this test exists to catch is the app finishing the load reporting zero assets: that
# renders an empty gallery which looks exactly like an empty database, while there is one asset
# sitting in the bucket. The pass is the app saying it could not reach the database.
#
# They are mutually exclusive by construction, not by timing: openDatabase in
# packages/user-interface/src/context/asset-database-source.tsx logs "Could not reach the database at
# ..." and RETURNS without setting the database path, so no load task is ever started and the
# "Load assets task completed" line cannot follow it. Waiting out a fixed 60s window to prove the
# empty load is absent and only then looking for the error therefore reached the same verdict a
# minute later than the app had already given it. Whichever line appears first is the app's answer.
#
# The window is generous rather than tight, because the AWS SDK retries a connection several times
# before giving up: the question is whether the app EVER says anything, not whether it says it
# quickly.
#
# The error is matched on openDatabase's own message naming the database path, not on any [ERROR]
# line at all. That older check passed on any unrelated error the app happened to log, which the
# header above already admitted could be a credential failure rather than the unreachable bucket.
EXPECTED_ERROR="Could not reach the database at $S3_DB_PATH"
EMPTY_LOAD="Load assets task completed: 0 assets loaded"
OUTCOME_WAIT_SECONDS=90

if ! wait_for_either_log "$TMP_DIR" "$OUTCOME_WAIT_SECONDS" "$EXPECTED_ERROR" "$EMPTY_LOAD"; then
    log_error "The app never logged \"$EXPECTED_ERROR\" in ${OUTCOME_WAIT_SECONDS}s"
    log_error "It neither completed the load nor logged an error, so the user is left looking at a screen that never resolves"
    log_error "Last 30 lines of app.log:"
    tail -30 "$TMP_DIR/app.log"
    exit 1
fi

if [ "$WAIT_FOR_EITHER_MATCH" = "second" ]; then
    log_error "The app reported a successful load of 0 assets from an unreachable bucket"
    log_error "There is an asset in that bucket; an empty gallery here is indistinguishable from an empty database"
    exit 1
fi

log_success "The app did not report an empty-but-successful load from the unreachable bucket"
log_success "The app reported an error for the unreachable bucket"
log_success "Test 43 passed: s3-failure"
exit 0
