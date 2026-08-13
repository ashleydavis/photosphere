#!/bin/bash

# Replicates a local database to an S3 DESTINATION through the Replicate Database dialog, then opens
# the replica and asserts its gallery loads the source's assets.
#
# Test 17 covers the same dialog with a filesystem destination only, so the S3 branch of that dialog
# (switching the destination type, choosing the destination's S3 credentials through the Configure
# Secrets modal, and writing the replica into a bucket) has never been driven.
#
# Opening the replica afterwards is what makes this more than "the dialog reported success": the
# assets can only be counted by reading them back out of the bucket.
#
# The `data-id` attributes this drives on the destination-type Select and inside the Configure Secrets
# modal were added for this test. They are markup only.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$TEST_DIR/../../../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 27 "s3-replicate"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
SOURCE_DB="$TMP_DIR/source-db"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running.
cleanup() {
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DEST_PATH="s3:$S3_EMULATOR_BUCKET/desktop-replica"
log_info "Replication destination: $S3_DEST_PATH"

# --- 1. A local source database with one asset in it. ---

log_info "Pre-creating the source database with the CLI and importing a fixture..."
( cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes ) || exit 1
( cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes ) || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# --- 2. Store the S3 credentials the destination will need. ---

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY"

# --- 3. Register the source database. ---

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"add-database-button"}'
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}'
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$SOURCE_DB\"}"
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'
wait_for_log "$TMP_DIR" "Database entry added"

# Registering the entry also opens the database, which spawns a worker, reads the assets and re-renders
# the databases page underneath whatever is on top of it. That takes tens of seconds, so left alone it
# lands in the middle of section 4 and disturbs the dialogs there: it has been seen closing the
# Configure Secrets modal's open Select between the option being clicked and the click being handled,
# leaving the modal saved with no credentials and the Start button disabled forever after. Waiting for
# it here means the rest of the test drives a quiet app.
#
# The wait is sound in a way the one that used to sit further down was not: the open is started by the
# registration above, so its completion is always after the line just matched, whichever order the two
# finish in. Down in section 4 the cursor had often already passed the line, and the test then waited
# out its timeout for a load that had already happened.
wait_for_log "$TMP_DIR" "Load assets task completed"

# --- 4. Replicate it into the bucket. ---

# No navigation back to the databases page: section 3 is already on it, and re-entering a route the
# app is already showing does not remount the page. The "Databases page loaded" event only fires when
# the databases or secrets lists change, so waiting for one after a no-op navigation waits for
# something nothing is going to emit. The two the registration above does cause are both behind the
# cursor by the time the wait for the load lands, which is what made this time out.
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}'
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

# Switch the destination to S3. The destination path field is cleared by this change, so it is typed
# afterwards, and the Select's button is read back so a click the list never took is caught here
# rather than several steps later where it looks like something else.
send_command "$APP_PORT" click '{"dataId":"replicate-dest-type-select"}'
send_command "$APP_PORT" click '{"dataId":"replicate-dest-type-option-s3"}'
wait_for_value "$APP_PORT" "replicate-dest-type-select" "S3"

# Choose the destination's S3 credentials through the Configure Secrets modal. Replication to S3 is
# blocked until a credential is chosen, so this is not optional decoration.
send_command "$APP_PORT" click '{"dataId":"replicate-configure-secrets-button"}'
wait_for_value "$APP_PORT" "configure-secrets-save" "Save"
send_command "$APP_PORT" click '{"dataId":"configure-secrets-s3-select"}'
# The option has to be on screen before it is clicked. The select opens its list asynchronously, and
# a click sent into a list that has not rendered goes nowhere while the test carries on regardless.
wait_for_value "$APP_PORT" "configure-secrets-s3-option-$SECRET_NAME" "$SECRET_NAME"
send_command "$APP_PORT" click "{\"dataId\":\"configure-secrets-s3-option-$SECRET_NAME\"}"
# The Select's button reads back whatever is chosen, so the choice is confirmed there before the modal
# is saved. Clicking an Option that is on screen is not the same as the Select having taken it: a
# re-render that closes the list between the two leaves the click landing on nothing, the modal saves
# with no credentials, and every failure after that points somewhere else.
wait_for_value "$APP_PORT" "configure-secrets-s3-select" "$SECRET_NAME"
send_command "$APP_PORT" click '{"dataId":"configure-secrets-save"}'

# The secrets modal must be gone before the replicate dialog underneath it is typed into. Without
# this the next three commands can land while the modal is still closing, and the failure that
# produces is silent: every click is logged as delivered, the start button does nothing useful, and
# the test waits out its whole timeout for a replication that was never started. Seen once in a
# sequential run, where an idle machine put all of these inside 600ms.
wait_for_value_gone "$APP_PORT" "configure-secrets-save" "Save" || exit 1

# The modal having closed is not the same as the credential having reached the replicate dialog's
# form, and it is the form that Start reads: the button stays disabled while the destination is S3
# and no S3 key is set. A disabled button swallows the click in silence, so the test then waits out
# its whole timeout for a replication that was never started (the driver now warns when a click
# lands on a disabled control, which is how this was caught). The dialog shows the chosen secret in
# its own text, so waiting for that is waiting for the state Start actually depends on.
wait_for_value "$APP_PORT" "replicate-database-dialog" "S3: $SECRET_NAME" || exit 1

# Opening the source database reloads the databases page behind the modal. A destination typed
# before that load lands is lost to the re-render, and the Start button then does nothing at all:
# every click is still logged as delivered, so the test sits out its whole timeout waiting for a
# replication that was never started. Seen twice, once in a sequential run and once with two copies
# of the suite running at the same time.
#
# Waiting on the completion line was not sound, because when the load happens is not fixed: it can
# run before this point or after it, and wait_for_log only searches after the last line it matched.
# Ahead of the cursor it returned at once on a load already finished; behind it, it could never match
# and burned the full 120s, which is how run 9 of a climb failed. Waiting for every load that started
# to have finished asks the real question and does not care about the order.
wait_for_asset_loads_to_settle "$TMP_DIR" || exit 1

send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$S3_DEST_PATH\"}"
wait_for_value "$APP_PORT" "replicate-dest-path-input" "$S3_DEST_PATH"

send_command "$APP_PORT" click '{"dataId":"replicate-mode-full"}'
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}'

wait_for_log "$TMP_DIR" "Replication completed for"
log_success "Replication to the S3 destination completed"

send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}'

# --- 5. The replica really is in the bucket and reads back. ---

# The database's own files must exist as objects under the destination prefix. A replication that
# reported success having written nothing would still pass the log wait above.
REPLICA_OBJECT_COUNT=$(bun "$REPO_DIR/scripts/s3-object.ts" count \
    --endpoint "$S3_ENDPOINT" \
    --bucket "$S3_EMULATOR_BUCKET" \
    --access-key "$S3_EMULATOR_ACCESS_KEY" \
    --secret-key "$S3_EMULATOR_SECRET_KEY" \
    --prefix "desktop-replica")
if [ "$REPLICA_OBJECT_COUNT" -lt 1 ]; then
    log_error "Replication reported success but wrote no objects under desktop-replica in the bucket"
    exit 1
fi
log_success "The replica wrote $REPLICA_OBJECT_COUNT objects into the bucket"

# Opening the replica counts its assets by reading them back out of S3, which is the assertion that
# the replication actually carried the data across rather than just the structure.
send_command "$APP_PORT" open-database "{\"path\":\"$S3_DEST_PATH\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
log_success "The S3 replica opened with the source's one asset"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 27 passed: s3-replicate"
