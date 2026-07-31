#!/bin/bash

# Substep 14a: open a desktop-created ENCRYPTED database on device and prove decryption works.
#
# The database is created and encrypted on the host by the CLI (real Node crypto), then seeded into the
# app sandbox. The encryption private key is stored in the device keychain (step 6b's secure store) as
# an encryption-key secret, so the worker vault (14b) resolves it natively and the mobile crypto shim
# (14a: native RSA-OAEP-SHA1 + AES-256-CBC) decrypts the assets. If the shim's OAEP padding or the
# vault wiring were wrong, the gallery would fail to decrypt rather than load.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 32 "encrypted-database"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"
DB_NAME="enc-db"
# The CLI's --key is a *vault key name*, not a file path: --generate-key stores the generated RSA
# key pair in the host vault under this name and never writes a PEM file. Every host CLI call here
# goes through run_cli, which points the vault at this test's own tmp dir and selects the plaintext
# vault, so the key never touches the real OS keychain. That isolation is also what lets this run on
# CI at all: a runner has no usable keychain (no libsecret on Linux, and `security` unavailable on
# the macOS image), which failed this test before every other test in the suite could even run.
KEY_NAME="smoke-test-enc-db-key"
DB_PATH="$TMP_DIR/$DB_NAME"

mkdir -p "$TMP_DIR"

# Remove any key left in the host vault by a previous run so --generate-key starts clean and the
# test is rerunnable. run_cli puts the vault under this test's tmp dir, so there is nothing to clean
# on a fresh checkout; it still matters for a rerun that kept tmp.
run_cli "$TMP_DIR" secrets remove --name "$KEY_NAME" --yes >/dev/null 2>&1 || true

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Create an encrypted database on the host: generate a key and add one asset through it.
run_cli "$TMP_DIR" init --db "$DB_PATH" --generate-key --key "$KEY_NAME" --yes || exit 1
run_cli "$TMP_DIR" add "$REPO_DIR/test/test.jpg" --db "$DB_PATH" --key "$KEY_NAME" --yes || exit 1

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the encrypted database files into the sandbox and its config entry.
"${PLATFORM}_seed_database" "$DB_PATH" "$DB_NAME"
"${PLATFORM}_seed_databases_config" "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]" || exit 1

# Seed the *worker-side* database registry too. resolve-storage-credentials.ts decides whether to
# open a database encrypted by looking up the path in the registry that node-api's getDatabases()
# reads, and taking that entry's encryption_key as the vault secret name. That registry is
# databases.toml under the config dir, which on device resolves sandbox-relative to
# .config/photosphere/databases.toml (the mobile `os.homedir()` shim returns ""). The app's own
# database list is a different file (databases.toml at the sandbox root), so without this one the
# worker finds no entry, hasAnyEncryptionSource stays false, and the database opens as plain storage
# and reads still-encrypted bytes instead of decrypting.
CONFIG_SEED="$TMP_DIR/config-seed"
rm -rf "$CONFIG_SEED"
mkdir -p "$CONFIG_SEED/photosphere"
cat > "$CONFIG_SEED/photosphere/databases.toml" <<TOML
[[databases]]
name = "$DB_NAME"
description = ""
path = "$DB_NAME"
encryption_key = "$DB_NAME"
TOML
"${PLATFORM}_seed_database" "$CONFIG_SEED" ".config"

# Add the private key into the device keychain as an encryption-key secret, through the app's own
# add-secret UI (the real path a secret takes into the keychain). The worker vault (14b) then resolves
# it by name. The key lives in the host vault, so read it back out with `secrets view --raw`; it is a
# multi-line PEM, so the whole type-command payload is built with python's json so the PEM is escaped.
KEY_PEM_RAW=$(run_cli "$TMP_DIR" secrets view --name "$KEY_NAME" --raw --yes)
if [ -z "$KEY_PEM_RAW" ]; then
    log_error "Could not read encryption key \"$KEY_NAME\" back from the host vault"
    exit 1
fi
PEM_TYPE_PAYLOAD=$(KEY_PEM_RAW="$KEY_PEM_RAW" python3 -c "import json,os;print(json.dumps({'dataId':'secret-private-key-input','text':os.environ['KEY_PEM_RAW']}))")

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" click '{"dataId":"secret-type-select"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"secret-type-option-encryption-key"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"secret-name-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" type "$PEM_TYPE_PAYLOAD" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
# "Secret added" is logged only after the keychain write has completed, so there is no async push to
# race: once this line appears the worker can resolve the encryption key by name.
wait_for_log "$TMP_DIR" "Secret added"

# Return to the gallery route (adding the secret left the app on the secrets page) so the gallery is
# mounted when the database opens, then open the encrypted database by path (the same control command
# the load-fixture test uses). The worker resolves the encryption key from the seeded registry
# (databases.toml) and the crypto shim decrypts the asset.
send_command "$APP_PORT" navigate '{"page":"gallery"}' || exit 1
send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1

# The gallery logs its loaded asset count once the (decrypted) assets stream in. The database holds
# exactly the one asset the CLI added through the encryption key, so a count of 1 proves the assets
# were read back and decrypted; a decryption failure fails the load task and this never appears.
#
# This asserts on the log line every other gallery test uses rather than on a "gallery-asset-count"
# data-id, which does not exist anywhere in the UI: reading it returned an empty string forever,
# independent of whether decryption worked, so it could never have passed.
wait_for_log "$TMP_DIR" "Gallery loaded: 1 assets"

# Thumbnail fetches require the asset-serving layer; ignore only those, never a decryption error.
check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'

log_success "Test 32 passed: encrypted-database"
