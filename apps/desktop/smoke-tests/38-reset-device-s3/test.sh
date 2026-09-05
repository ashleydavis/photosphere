#!/bin/bash

# Proves "Reset device" does not touch a database in S3.
#
# A bucket is shared with every other device the user owns, and nothing on this machine owns it, so a
# reset here must remove the entry and the credentials and leave every object where it is. Nothing in
# the reset opens remote storage, which is what makes that true, and this test is what proves it:
# a real database is created in a real bucket (a local MinIO), a photo is imported into it, the
# device is reset, and the bucket is then read back with the CLI and still holds the photo.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 38 "reset-device-s3"

S3_STATE_DIR="$TMP_DIR/s3"
SECRET_NAME="smoke-test-s3"
DB_NAME="S3 Test DB"
DATABASES_TOML="$TMP_DIR/config/databases.toml"
# The vault and config the CLI reads the bucket with, kept apart from the app's so the reset cannot
# take the credentials this test checks the bucket with.
CLI_VAULT_DIR="$TMP_DIR/cli-vault"
CLI_CONFIG_DIR="$TMP_DIR/cli-config"

# Stop the app AND the emulator, so a failed assertion never leaves a MinIO server running.
cleanup() {
    cleanup_apps "$TMP_DIR"
    stop_s3_emulator "$S3_STATE_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

start_s3_emulator "$S3_STATE_DIR"
S3_DB_PATH="s3:$S3_EMULATOR_BUCKET/desktop-reset"
log_info "Database path: $S3_DB_PATH"

# The credentials the CLI reads the bucket with, under "default:s3", which is the name it looks for
# when a database entry names no secret of its own.
mkdir -p "$CLI_CONFIG_DIR"
write_vault_secret "$CLI_VAULT_DIR" "default:s3" "s3-credentials" \
    "{\"region\":\"us-east-1\",\"accessKeyId\":\"$S3_EMULATOR_ACCESS_KEY\",\"secretAccessKey\":\"$S3_EMULATOR_SECRET_KEY\",\"endpoint\":\"$S3_ENDPOINT\"}"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The credentials, through the app's own Add Secret dialog, the way a user stores them.
send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY"

# The database, in the bucket, through the New Database dialog.
send_command "$APP_PORT" menu '{"itemId":"new-database"}'
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type "{\"dataId\":\"database-name-input\",\"text\":\"$DB_NAME\"}"
send_command "$APP_PORT" click '{"dataId":"database-storage-type-select"}'
send_command "$APP_PORT" click '{"dataId":"database-storage-type-option-s3"}'
wait_for_value "$APP_PORT" "chosen-s3-secret" "None selected"
send_command "$APP_PORT" click '{"dataId":"select-s3-button"}'
wait_for_log "$TMP_DIR" "Select secret modal ready"
send_command "$APP_PORT" click '{"dataId":"secret-select-button"}'
wait_for_value "$APP_PORT" "chosen-s3-secret" "$SECRET_NAME"
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$S3_DB_PATH\"}"
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}'
wait_for_log "$TMP_DIR" "Database created"

# A photo in it, so the bucket holds something a user would be devastated to lose.
send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"
send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"
send_command "$APP_PORT" click '{"dataId":"import-button"}'
wait_for_log "$TMP_DIR" "Import page ready"
send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\"]}"
wait_for_log "$TMP_DIR" "1 assets imported"
log_success "The database in the bucket holds the imported photo"

#
# Reads the database back out of the bucket with the CLI and prints what it said into the given file.
# Returns non-zero when the database cannot be read.
#
# The CLI is given a vault and a config directory of its own, holding nothing but the emulator's
# credentials under the name the CLI reads them from ("default:s3"). Its own, because the app's are
# about to be wiped by the reset under test, and this check has to work identically before and after
# that: a reader that loses its credentials to the reset cannot tell a deleted database from a
# forgotten password.
# Usage: read_bucket_database <output-file>
#
read_bucket_database() {
    local output_file="$1"
    (cd "$CLI_DIR" && PHOTOSPHERE_VAULT_DIR="$CLI_VAULT_DIR" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        PHOTOSPHERE_CONFIG_DIR="$CLI_CONFIG_DIR" \
        bun run start -- summary --db "$S3_DB_PATH" --yes > "$output_file" 2>&1)
}

# Read it before the reset as well as after. A check that cannot tell "the reset destroyed it" from
# "this check never worked" proves nothing about the reset.
BEFORE_OUTPUT="$TMP_DIR/s3-summary-before.txt"
if ! read_bucket_database "$BEFORE_OUTPUT"; then
    log_error "The bucket could not be read before the reset, so this test cannot say what the reset did. The CLI said:"
    sed 's/^/  /' "$BEFORE_OUTPUT"
    exit 1
fi
log_success "The database in the bucket reads back before the reset"

# Reset the device.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
wait_for_value "$APP_PORT" "configuration-dialog" "Reset device"
send_command "$APP_PORT" click '{"dataId":"reset-device-open"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "cannot be undone"
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-confirm"}'
wait_for_log "$TMP_DIR" "Device reset:"

if [ -f "$DATABASES_TOML" ] && grep -q "$DB_NAME" "$DATABASES_TOML"; then
    log_error "The app reported the reset but $DATABASES_TOML still holds the S3 entry"
    cat "$DATABASES_TOML"
    exit 1
fi
log_success "The S3 database entry is gone from the configured list"

if vault_has_secret "$TMP_DIR/vault" "$SECRET_NAME"; then
    log_error "The app reported the reset but the vault still holds '$SECRET_NAME'"
    exit 1
fi
log_success "The S3 credentials are gone from the vault"

# The assertion this test exists for. The app's own credentials have just been deleted, so the bucket
# is read with the CLI's environment-variable credentials instead: the database must still be there,
# and the photo with it.
stop_app "$APP_PORT" "$TMP_DIR"

SUMMARY_OUTPUT="$TMP_DIR/s3-summary.txt"
if ! read_bucket_database "$SUMMARY_OUTPUT"; then
    log_error "The reset DESTROYED the database in the bucket: the CLI cannot read it back. It said:"
    sed 's/^/  /' "$SUMMARY_OUTPUT"
    exit 1
fi

# The imported count, not the file count: an empty database still holds its README, so a file count
# cannot tell a surviving library from an emptied one.
if ! grep -qE "Files imported:.*[1-9]" "$SUMMARY_OUTPUT"; then
    log_error "The database in the bucket came back with no imported files after the reset:"
    sed 's/^/  /' "$SUMMARY_OUTPUT"
    exit 1
fi
log_success "The database in the bucket, and the photo in it, survived the reset"

check_no_errors "$TMP_DIR"

log_success "Test 38 passed: reset-device-s3"
