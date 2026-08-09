#!/bin/bash

# The whole real-world flow the app exists for, end to end: an encrypted database in an S3 bucket,
# shared to the phone over the LAN with the CLI, opened on the phone, partially replicated onto the
# device, edited on the device, and synced back up to the bucket.
#
# Nothing else in the suite proves an edit made on device reaches an encrypted S3 origin. Test 41
# creates an S3 database from the device and test 42 syncs against an S3 origin, but both build the
# credentials on the device by hand and neither one is encrypted; test 26 receives a database over the
# LAN but it is a plain local directory with nothing behind it. This is the first test where the S3
# credentials and the encryption key arrive on the phone the way a user's would (inside a shared
# payload from another machine) and are then used, from inside the embedded JS engine, to read and
# write a bucket.
#
# It is also the first test that asserts the sync early-out. `Sync completed: nothing to sync` is a
# different line from `Sync completed: changes synced`, so a sync that ran and found both sides
# identical is distinguishable here from one that pushed changes. Asserting both, in that order,
# is what proves the flag is real rather than a constant.
#
# The replica left on the device is UNENCRYPTED, deliberately. replicateDatabaseHandler copies through
# the decrypted asset-storage layer and the dialog leaves destEncryptionKey unset by default, so a
# plain replica of an encrypted origin is coherent. It does mean device storage holds plaintext copies
# of assets that are encrypted at the origin. Encrypting the replica needs no app change (the
# replicate dialog can name the received key through replicate-configure-secrets-button), but
# registering it afterwards does, because the Add Database dialog's "Encrypted" switch carries no
# data-id. That is out of scope here.
#
# The endpoint stored in the shared S3 secret is the DEVICE-reachable one, and the host CLI is given
# the same string rather than loopback. MinIO binds 0.0.0.0 so both reach it, and using one endpoint
# for both is what keeps the share payload correct for the device that receives it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 45 "s3-share-replica-sync"

S3_STATE_DIR="$TMP_DIR/s3"
S3_SECRET_NAME="shared-s3"
ENC_KEY_NAME="shared-enc-key"
DB_NAME="shared-db"
REPLICA_NAME="local-replica"
PAIRING_CODE="4321"

# The description typed on the device. Named once because it is written in the app, read back from the
# app, and read out of the bucket by the CLI, and those three have to be asking about the same text.
DESCRIPTION="Edited on the device"

# The CLI sender has to reach the device's receiver, so check for that before the trap is armed:
# failing here must not run a teardown for an app that was never started. Test 26 does the same.
require_lan_bridge

# Stop the app AND the S3 emulator, so a failed assertion never leaves a MinIO server running.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/shared-encrypted"
log_info "Encrypted database on S3: $S3_DB_PATH"

# run_cli isolates the CLI's own vault and config under this test's tmp dir. These are what the CLI
# falls back to when the database entry it is working on names no vault secret, which is the case for
# the `init` below (the entry does not exist yet).
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="$S3_ENDPOINT"
export AWS_REGION="us-east-1"

#
# Runs a CLI command and fails the test with the CLI's own output when it does not succeed. The same
# treatment create_database gives its calls, which matters here because every one of these is setting
# up state the rest of the test silently depends on.
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

# --- 1. Build the encrypted database in the bucket, on the host. ---

# jq builds the JSON so the credentials are never hand-quoted. The field names are the ones
# resolveDatabaseSharePayload reads out of the secret (packages/api/src/lan-share/lan-share-resolve.ts);
# a mismatch here would share a credential object full of undefined and fail on the device instead.
S3_SECRET_JSON="$(jq -nc \
    --arg region "us-east-1" \
    --arg accessKeyId "$S3_EMULATOR_ACCESS_KEY" \
    --arg secretAccessKey "$S3_EMULATOR_SECRET_KEY" \
    --arg endpoint "$S3_ENDPOINT" \
    '{region: $region, accessKeyId: $accessKeyId, secretAccessKey: $secretAccessKey, endpoint: $endpoint}')"

log_info "Building the encrypted S3 database on the host with the CLI"
cli_expect_success "Adding the S3 credentials secret" \
    secrets add --yes --name "$S3_SECRET_NAME" --type s3-credentials --value "$S3_SECRET_JSON"

# --generate-key creates the named key in the vault, so this is what puts the encryption key there for
# the share to carry. --key takes a vault secret NAME, not a file path, despite what its help says.
cli_expect_success "Initialising the encrypted database on S3" \
    init --db "$S3_DB_PATH" --generate-key --key "$ENC_KEY_NAME" --yes

# The database entry is what names both secrets, and it is the entry that gets shared: the device
# receives the credentials and the key because this entry references them by name.
cli_expect_success "Registering the database with its credentials and key" \
    dbs add --yes --name "$DB_NAME" --description "Encrypted S3 database" --path "$S3_DB_PATH" \
        --s3-cred "$S3_SECRET_NAME" --encryption-key "$ENC_KEY_NAME"

cli_expect_success "Adding a photo to the encrypted database" \
    add "$REPO_DIR/test/test.jpg" --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes

# --- 2. Receive it on the device, through the real Receive Database dialog. ---

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's localStorage
# and the keychain) so this test starts from a known state. Done before launch, with the app stopped,
# so nothing can write state back underneath it.
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
# test 26 does. The sender's discovery has a 60 second budget, so this is slack rather than a race.
sleep 3
log_info "Sending the database from the host CLI..."
cli_send_expect_success "$TMP_DIR" dbs send --yes --name "$DB_NAME" --code "$PAIRING_CODE"

wait_for_log "$TMP_DIR" "Database review step"
send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database imported"

# On mobile the dialog is a drawer that stays mounted (visibility hidden) on its success step over the
# page, so close it before reading the databases list behind it.
send_command "$APP_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1

# The entry really persisted. This is also what proves the S3 credentials and the encryption key
# landed in the device keychain, because the entry references them by name and opening it below would
# fail without them.
wait_for_value "$APP_PORT" "database-row-name-$DB_NAME" "$DB_NAME"
log_success "The encrypted S3 database was received onto the device over the LAN"

# --- 3. Open the received S3 database and see the one photo. ---

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
# Assert which entry index 0 is before clicking it, rather than trusting the list order. The button's
# text is the entry name followed by its path.
wait_for_value "$APP_PORT" "database-list-item-0" "$DB_NAME"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"
log_success "The shared S3 credentials and encryption key both work from inside the embedded JS engine"

# --- 4. Close the database through the app's own UI. ---

# Closing here is not tidiness: it removes the auto-open race that tests 17 and 36 both had to work
# around before opening a card's action menu, because with no database open there is no late open to
# re-render the card list underneath the menu.
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1

# The no-database screen renders only when no database is open, so its presence is the assertion.
wait_for_value "$APP_PORT" "no-database-loaded" "."
log_success "The database was closed through the app's own UI"

# --- 5. Replicate the S3 database partially onto the device. ---

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

# A partial replica copies the merkle trees but no thumbnails, which is what leaves prefetch-database
# something to do below. replicate() writes origin = the source path into the destination's
# .db/config.json, so the replica points back at the S3 path with no extra step, and the sync handler
# resolves that origin's credentials from the received shared-db entry, which names the same path.
send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"
send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1
log_success "The encrypted S3 database was partially replicated onto the device"

# --- 6. Register and open the partial replica, and see the one photo. ---

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"
wait_for_log "$TMP_DIR" "Database opened"

send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"

# Opening a partial replica fire-and-forget queues a prefetch-database task. Its effect on device
# storage is the assertion, the same one test 42 makes: the thumb directory, absent from a partial
# replica, appears once the prefetch has pulled thumbnails out of the bucket.
if ! "${PLATFORM}_wait_for_file" "$REPLICA_NAME/thumb"; then
    log_error "Prefetch from the encrypted S3 origin never produced $REPLICA_NAME/thumb on the device"
    exit 1
fi
log_success "The prefetch pulled thumbnails down out of the bucket"

# --- 7. A sync with nothing to do must say so. ---

# The origin's root hash before any edit, so the sync below can be judged on whether it changed the
# origin at all. A sync that reports it pushed changes and leaves this untouched has taken one of
# syncDatabase's early returns rather than merging anything, which is invisible from the app: the
# worker's own log never reaches app.log.
ORIGIN_HASH_BEFORE="$(run_cli "$TMP_DIR" root-hash --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes 2>/dev/null | tail -1 | tr -d '\r')"
log_info "Origin root hash before the edit: $ORIGIN_HASH_BEFORE"

# Trip the scheduler's 10 second debounce without waiting it out, as tests 34 and 42 do.
send_command "$APP_PORT" notify-database-edited '{}' || exit 1

wait_for_log "$TMP_DIR" "Sync started"
# The whole point of the synced flag. Waiting on a bare "Sync completed" here would pass whether the
# sync transferred everything or nothing; this asserts syncDatabases took its identical-content-hash
# early-out, which is only possible if the sync really reached the encrypted S3 origin and compared
# against it.
wait_for_log "$TMP_DIR" "Sync completed: nothing to sync"
log_success "A sync against the encrypted S3 origin ran and correctly found nothing to do"

# --- 8. Edit the photo's description on the device. ---

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"

send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"asset-description-input\",\"text\":\"$DESCRIPTION\"}" || exit 1

# Read the description back first. It is the cheaper of the two assertions and it fails in a way that
# says which half went wrong: the field holding the text but no sync following means the edit reached
# React and not the database, which is a different fault from the text never landing at all.
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The description was edited on the device and is shown in the info panel"

# The race-free signal that the edit was persisted, rather than sleeping out the 500ms description
# debounce: persistDatabaseOps calls platform.notifyDatabaseEdited() only after the apply-database-ops
# POST has resolved, and that is what schedules this sync.
wait_for_log "$TMP_DIR" "Sync started"

# --- 9. That sync must have done work. ---

# Together with step 7 this is what proves the synced flag is real and not always the same value.
wait_for_log "$TMP_DIR" "Sync completed: changes synced"

# Before asking whether the edit reached the origin, establish that it reached the device's own disk.
# Without this the test cannot say which half of the journey lost it, and the two failures look
# identical from the origin end. Reopening the replica is what makes this a disk read: the panel is
# bound to React state that was set the moment the user typed, so it would report the edit whether or
# not a byte of it was ever written.
# Closed first, not reopened directly. The replica is already the open database, and opening the one
# that is already open cancels the task source the first open established; the engine pool remembers a
# cancelled source, so the load queued against it is dropped and never completes. Test 41 records the
# same trap. Closing and opening again is a genuine reload.
send_command "$APP_PORT" click '{"dataId":"asset-view-close-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1
wait_for_value "$APP_PORT" "no-database-loaded" "."

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
wait_for_value "$APP_PORT" "database-list-item-1" "$REPLICA_NAME"
send_command "$APP_PORT" click '{"dataId":"database-list-item-1"}' || exit 1
# Anchored on the load starting rather than on the database being opened. "Database opened" and
# "Gallery items rendered" race each other (the assets stream in while the open completes), so
# neither can be waited on before the other; the load-start line names the database and is emitted
# before both, which makes the next "Gallery items rendered" after it unambiguously this one's.
wait_for_log "$TMP_DIR" "Starting load for database: \"$REPLICA_NAME\""
wait_for_log "$TMP_DIR" "Gallery items rendered"

send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"
send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The edit is on the device's own disk, in the replica"

# Read the bucket from the host, with the CLI, before asking the app about it. The app's own answer
# cannot separate "the sync did not push the edit" from "the app is showing a stale record", because
# both produce an empty description on screen. A separate process opening the encrypted database from
# scratch can only report what is actually stored, so this is what says which half is at fault when
# this test fails. It is also the same check the desktop test makes, for the same reason.
ORIGIN_ASSET_ID="$(run_cli "$TMP_DIR" list --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
if [ -z "$ORIGIN_ASSET_ID" ]; then
    log_error "Could not find the asset's id in the encrypted S3 database."
    exit 1
fi

# Replicated down to a plain local copy first, because `psi info` carries no --key option and so
# cannot open an encrypted database at all. Replicating decrypts on the way out, which leaves a
# database `info` can read. The replica is this test's own scratch copy and is read, never written.
ORIGIN_COPY="$TMP_DIR/origin-check"
if ! ORIGIN_COPY_OUTPUT="$(run_cli "$TMP_DIR" replicate --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --dest "$ORIGIN_COPY" --yes 2>&1)"; then
    log_error "Could not replicate the encrypted S3 database to read it back. The CLI said:"
    echo "$ORIGIN_COPY_OUTPUT" | sed 's/^/  /'
    exit 1
fi

ORIGIN_HASH_AFTER="$(run_cli "$TMP_DIR" root-hash --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes 2>/dev/null | tail -1 | tr -d '\r')"
log_info "Origin root hash after the sync:  $ORIGIN_HASH_AFTER"

ORIGIN_INFO="$(run_cli "$TMP_DIR" info "$ORIGIN_ASSET_ID" --db "$ORIGIN_COPY" --yes 2>&1)"
if ! echo "$ORIGIN_INFO" | grep -qF "$DESCRIPTION"; then
    if [ "$ORIGIN_HASH_BEFORE" = "$ORIGIN_HASH_AFTER" ]; then
        log_error "The sync reported it pushed changes but did not write to the origin at all: its root"
        log_error "hash is unchanged ($ORIGIN_HASH_AFTER). syncDatabase took an early return."
    else
        log_error "The sync wrote to the origin (root hash changed) but the edit is not among what it wrote."
    fi
    log_error "The sync reported it pushed changes, but the encrypted S3 database does not hold the edit."
    log_error "'psi info $ORIGIN_ASSET_ID' said:"
    echo "$ORIGIN_INFO" | sed 's/^/  /'
    exit 1
fi
log_success "The edit was pushed up to the encrypted S3 origin (confirmed by reading the bucket)"

# --- 10. Read the edit back out of the bucket. ---

# Close the asset view before switching database. Leaving it open leaves an AssetView and an AssetInfo
# mounted against the replica's copy of the asset, and the replica and the origin hold the same record
# id, so nothing about the incoming database makes them re-read it: the panel below would be answering
# for the database this test has just finished with. The stale view is visible in the app log as an
# "AssetView opened" that fires on its own when the new gallery renders, before this test has clicked
# anything.
send_command "$APP_PORT" click '{"dataId":"asset-view-close-button"}' || exit 1

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"
# shared-db was registered first, so it keeps index 0 and the replica is index 1. Asserted rather
# than assumed, because opening the replica here would prove nothing about the origin.
wait_for_value "$APP_PORT" "database-list-item-0" "$DB_NAME"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1

# Every wait here has to name something that cannot already have happened, because wait_for_log starts
# from wherever the last wait left its cursor and both databases in this test produce identical lines:
# they hold one asset each, so "Gallery loaded: 1 assets" and "Gallery items rendered" are emitted by
# the replica just as they are by the origin. A wait on either of those matched a render belonging to
# the database being navigated away from, and the test then acted on a gallery that had not been
# rebuilt yet. "Database opened" names the database, so it anchors the cursor unambiguously; the
# "Gallery items rendered" after it is then guaranteed to be this database's.
#
# There is no navigation here on purpose. The app is already on the gallery, and navigating to a route
# it is already on produces a second render whose only observable signal is a line indistinguishable
# from the first one's, which is the ambiguity this is trying to escape.
wait_for_log "$TMP_DIR" "Starting load for database: \"$S3_DB_PATH\""
wait_for_log "$TMP_DIR" "Gallery items rendered"

# long-press-click does not wait for its element (doLongPressClick has no waitForElement, unlike
# click), so the thumbnail has to be there before this is sent rather than during it.
send_command "$APP_PORT" long-press-click '{"dataId":"gallery-thumb"}' || exit 1
wait_for_log "$TMP_DIR" "AssetView opened"
send_command "$APP_PORT" click '{"dataId":"open-info-button"}' || exit 1

# The test's real conclusion: an edit made on the device reached an encrypted database in an S3
# bucket, through the sync, and reads back decrypted.
wait_for_value "$APP_PORT" "asset-description-input" "$DESCRIPTION"
log_success "The edit made on the device is in the encrypted S3 database and reads back decrypted"

# Thumbnail fetches go through the asset-serving layer; ignore only those, as tests 41 and 42 do.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 45 passed: s3-share-replica-sync"
