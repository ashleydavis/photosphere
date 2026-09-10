#!/bin/bash

# A photo imported on the device reaches an encrypted S3 origin, as an object, with its bytes intact.
#
# Nothing else in the suite proves that. Test 45 syncs an edit up to an encrypted S3 origin, but an
# edit is a record, and a record is written as a whole buffer through `write`. An asset file is
# written through `writeStream`, and on an encrypted database `EncryptedStorage.writeStreamHashed`
# cannot hand the plaintext hash down to the store, so it delegates to `writeStream` and every upload
# takes `@aws-sdk/lib-storage`'s multipart path however small the file is. That path async-iterates
# the body, which on mobile is the encryption stream: the shim `Transform`. Measured on a Pixel 6
# against a real library, every original failed there with "not a function", the sync caught it and
# carried on, and after 2 hours 18 minutes of importing not one byte had reached the origin. The sync
# still reported that it pushed changes, which is why this test believes nothing the app says and
# reads the bucket from the host instead.
#
# The fixture is generated rather than committed, so the repository does not grow a binary. It is
# random noise, so JPEG cannot compress it away, and big enough to be more than one 5 MiB part: a
# single-part upload and a multi-part one take different code inside the SDK and only the second one
# is exercised by a file this size.
#
# The photo goes in through the picker path (staged into the sandbox's import directory and named
# with pick-files) rather than through the device photo library, because that is the import test 4
# already proves works and the subject here is what happens after the import, not the import itself.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 56 "large-asset-push"

S3_STATE_DIR="$TMP_DIR/s3"
S3_SECRET_NAME="shared-s3"
ENC_KEY_NAME="shared-enc-key"
DB_NAME="shared-db"
REPLICA_NAME="local-replica"
# Drawn per run, never hardcoded: the code is the only thing that tells two concurrent shares apart.
PAIRING_CODE="$(allocate_pairing_code)"

# The generated photo, on the host and under the name it is imported by on the device.
FIXTURE_NAME="large-noise.jpg"
FIXTURE_PATH="$TMP_DIR/import-images/$FIXTURE_NAME"

# The CLI sender has to reach the device's receiver, so check for that before the trap is armed:
# failing here must not run a teardown for an app that was never started. Tests 26 and 45 do the same.
require_lan_bridge

# Stop the app AND the S3 emulator, so a failed assertion never leaves a MinIO server running.
trap 'stop_app "$APP_PORT" "$TMP_DIR"; stop_s3_emulator "$S3_STATE_DIR"' EXIT

mkdir -p "$TMP_DIR/import-images"

# --- 1. Generate the photo the whole test is about. ---

# 3000x3000 of random noise comes out around 6.5 MB as a JPEG, which is more than one upload part.
# ImageMagick 7 calls it `magick` and ImageMagick 6 calls it `convert`; the repository's own Image
# class tries them in that order and the Release workflow verifies `magick|convert`, so both are
# expected to exist in the wild and this picks whichever does.
if command -v magick >/dev/null 2>&1; then
    IMAGE_MAGICK="magick"
elif command -v convert >/dev/null 2>&1; then
    IMAGE_MAGICK="convert"
else
    log_error "Neither 'magick' nor 'convert' is on PATH, so the test photo cannot be generated."
    log_error "ImageMagick is required by the CLI's own import as well; install it and run this again."
    exit 1
fi

if ! MAGICK_OUTPUT="$($IMAGE_MAGICK -size 3000x3000 xc:gray +noise Random -quality 92 "$FIXTURE_PATH" 2>&1)"; then
    log_error "Could not generate the test photo with $IMAGE_MAGICK. It said:"
    echo "$MAGICK_OUTPUT" | sed 's/^/  /'
    exit 1
fi

FIXTURE_BYTES="$(wc -c < "$FIXTURE_PATH" | tr -d ' ')"
if [ "$FIXTURE_BYTES" -le 5242880 ]; then
    log_error "The generated photo is $FIXTURE_BYTES bytes, which fits in a single 5 MiB upload part."
    log_error "The multi-part path is the one this test exists to exercise, so it must be larger."
    exit 1
fi
log_info "Generated a $FIXTURE_BYTES byte test photo, which is more than one upload part"

# --- 2. Build the encrypted database in the bucket, on the host. ---

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/large-asset-push"
log_info "Encrypted database on S3: $S3_DB_PATH"

# run_cli isolates the CLI's own vault and config under this test's tmp dir. These are what the CLI
# falls back to when the database entry it is working on names no vault secret, which is the case for
# the `init` below (the entry does not exist yet).
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="$S3_ENDPOINT"
export AWS_REGION="us-east-1"

#
# Runs a CLI command and fails the test with the CLI's own output when it does not succeed. Every one
# of these sets up state the rest of the test silently depends on, which is why none of them are
# allowed to fail quietly.
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

# jq builds the JSON so the credentials are never hand-quoted. The field names are the ones
# resolveDatabaseSharePayload reads out of the secret (packages/api/src/lan-share/lan-share-resolve.ts).
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

# The database is left empty on purpose. The photo imported below is then the only asset there has
# ever been, so the single id `psi list` reports at the end can only be that photo's, with nothing to
# tell apart and nothing to pick between.

# --- 3. Receive it on the device, through the real Receive Database dialog. ---

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
# tests 26 and 45 do. The sender's discovery has a 60 second budget, so this is slack rather than a race.
sleep 3
log_info "Sending the database from the host CLI..."
cli_send_expect_success "$TMP_DIR" dbs send --yes --name "$DB_NAME" --code "$PAIRING_CODE"

wait_for_log "$TMP_DIR" "Database review step"
send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database imported"

# On mobile the dialog is a drawer that stays mounted (visibility hidden) on its success step over the
# page, so close it before reading the databases list behind it.
send_command "$APP_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1

# The entry really persisted, which is also what proves the S3 credentials and the encryption key
# landed in the device keychain: the entry references them by name and everything below would fail
# without them.
wait_for_value "$APP_PORT" "database-row-name-$DB_NAME" "$DB_NAME"
log_success "The encrypted S3 database was received onto the device over the LAN"

# --- 4. Replicate it onto the device and open the replica. ---

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened"

# replicate() writes origin = the source path into the destination's .db/config.json, so the replica
# points back at the S3 path with no extra step, and the sync handler resolves that origin's
# credentials from the received shared-db entry, which names the same path. Partial is what a phone
# really holds, and it is the target of the push either way: the partial filter in syncDatabases
# applies to the target of a copy, and the target here is the origin.
send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for"
send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1
log_success "The encrypted S3 database was replicated onto the device"

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$REPLICA_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"
wait_for_log "$TMP_DIR" "Database opened"

# --- 5. Import the generated photo into the replica, on the device. ---

# The picker cannot be automated, so its result is injected the way test 4 does it: the file is
# copied into the sandbox's import temp directory and its sandbox-relative path is staged with
# pick-files, so clicking import imports exactly that path.
"${PLATFORM}_seed_database" "$TMP_DIR/import-images" ".import-tmp" || exit 1

# The app is on the databases page, and the import button lives on the gallery, so go there first.
send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"

send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
wait_for_log "$TMP_DIR" "Import page ready"

send_command "$APP_PORT" pick-files "{\"paths\":[\".import-tmp/$FIXTURE_NAME\"]}" || exit 1
send_command "$APP_PORT" click '{"dataId":"import-files-button"}' || exit 1
wait_for_log "$TMP_DIR" "1 assets imported"
log_success "The photo was imported into the replica on the device"

# --- 6. Sync, which is what has to push the original up to the bucket. ---

# Trip the scheduler's 10 second debounce without waiting it out, as tests 34, 42 and 45 do.
send_command "$APP_PORT" notify-database-edited '{}' || exit 1

wait_for_log "$TMP_DIR" "Sync started"
wait_for_log "$TMP_DIR" "Sync completed: changes synced"

# That line is not the assertion and cannot be: syncDatabases catches a file it could not copy,
# counts it as left behind and finishes the pass reporting that it synced changes. The measured
# failure looked exactly like a successful sync from here.
log_info "A sync ran and reported that it pushed changes; reading the bucket to find out what it really pushed"

# --- 7. Read the bucket from the host and prove the original is in it. ---

ORIGIN_ASSET_ID="$(run_cli "$TMP_DIR" list --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
if [ -z "$ORIGIN_ASSET_ID" ]; then
    log_error "The encrypted S3 database holds no asset at all, so the sync pushed neither the record nor the file."
    exit 1
fi
log_info "The origin holds the asset record: $ORIGIN_ASSET_ID"

# `psi export` reads the object out of the bucket and decrypts it, so this is the bucket's own answer
# rather than the app's. It is also the assertion the app cannot fake: the record reaching the origin
# is a buffer write and works with or without the fix, and only the file is streamed.
EXPORTED_PATH="$TMP_DIR/exported-original.jpg"
if ! EXPORT_OUTPUT="$(run_cli "$TMP_DIR" export "$ORIGIN_ASSET_ID" "$EXPORTED_PATH" --type original --db "$S3_DB_PATH" --key "$ENC_KEY_NAME" --yes 2>&1)"; then
    log_error "The original is not in the bucket: exporting it from the encrypted S3 database failed."
    log_error "The record made it up (it is written as a whole buffer) and the file did not (it is streamed)."
    log_error "'psi export $ORIGIN_ASSET_ID' said:"
    echo "$EXPORT_OUTPUT" | sed 's/^/  /'
    exit 1
fi

if [ ! -f "$EXPORTED_PATH" ]; then
    log_error "'psi export' succeeded but wrote no file to $EXPORTED_PATH."
    exit 1
fi

EXPORTED_BYTES="$(wc -c < "$EXPORTED_PATH" | tr -d ' ')"
if [ "$EXPORTED_BYTES" != "$FIXTURE_BYTES" ]; then
    log_error "The original in the bucket is $EXPORTED_BYTES bytes and the photo imported was $FIXTURE_BYTES."
    log_error "Something reached the origin, but not all of it: a multi-part upload that loses a part"
    log_error "ends up exactly like this."
    exit 1
fi

# Length alone would pass for an object of the right size full of the wrong bytes, which is what a
# multi-part upload sending its parts in the wrong order produces.
if ! cmp -s "$FIXTURE_PATH" "$EXPORTED_PATH"; then
    log_error "The original in the bucket is the right length but is not the photo that was imported."
    exit 1
fi
log_success "The original is in the encrypted S3 bucket, byte for byte, having been uploaded in parts from the device"

# Thumbnail fetches go through the asset-serving layer; ignore only those, as tests 41, 42 and 45 do.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1

log_success "Test 56 passed: large-asset-push"
