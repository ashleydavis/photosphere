#!/bin/bash

# Exercises "Reset device" on the Configuration dialog: both cancels leave everything in place, and
# confirming both steps empties the database list, the vault and the app's config directory.
#
# The assertion that matters most here is the last one. On a desktop a database sits wherever the
# user put it and may be the only copy of their photos, so the reset must forget the entry and leave
# every file of it alone. This test creates its database outside the app's config directory, exactly
# as a user does, and checks it is still there afterwards.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 37 "reset-device"

DATABASES_TOML="$TMP_DIR/config/databases.toml"
# Where the app keeps what it works out about a database (the hash cache, the import record). Set for
# every test by the temp-directory allocator, and emptied by the reset along with the config.
CACHE_DIR="$PHOTOSPHERE_CACHE_DIR"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

#
# Fails the test when the database entry or the secret is not where it should be. Used after each
# cancel: a cancel that removed anything is the worst failure this feature can have.
# Usage: require_state_intact <what-was-cancelled>
#
require_state_intact() {
    local moment="$1"
    if ! grep -q 'My Test DB' "$DATABASES_TOML"; then
        log_error "$moment removed the database entry from $DATABASES_TOML"
        cat "$DATABASES_TOML"
        exit 1
    fi
    if ! vault_has_secret "$TMP_DIR/vault" test-secret; then
        log_error "$moment deleted the secret from the vault"
        exit 1
    fi
    log_success "$moment left the database entry and the secret in place"
}

#
# Opens the Configuration dialog and the reset confirmation on its first step.
#
open_reset_dialog() {
    send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
    wait_for_value "$APP_PORT" "configuration-dialog" "Reset device"
    send_command "$APP_PORT" click '{"dataId":"reset-device-open"}'
    wait_for_value "$APP_PORT" "reset-device-dialog" "cannot be undone"
}

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes || exit 1
cd "$DESKTOP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# A database entry and a secret, added the way a user adds them, so the reset has something real to
# remove.
send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"
send_command "$APP_PORT" click '{"dataId":"add-database-button"}'
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'
wait_for_log "$TMP_DIR" "Database entry added"

# One photo imported into it, so the database on disk has something to lose and the app has written
# a real hash cache and import record into its cache directory for the reset to clear.
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

if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
    log_error "The import wrote nothing into $CACHE_DIR, so this test cannot show the reset clears it"
    exit 1
fi
log_success "The import left the app something to clear in its cache directory"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}'
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret added"

require_state_intact "Setting up"

# Cancelling on the first step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-cancel"}'
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "cannot be undone" || exit 1
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}'
require_state_intact "Cancelling on the first step"

# Cancelling on the final step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-final-cancel"}'
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "Last chance" || exit 1
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}'
require_state_intact "Cancelling on the final step"

# Confirming both steps.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-confirm"}'
wait_for_log "$TMP_DIR" "Device reset:"

# The log line alone proves nothing: it is written straight after the reset returns, so a reset that
# removed nothing leaves it intact. Every assertion below reads the state back.
if [ -f "$DATABASES_TOML" ] && grep -q 'My Test DB' "$DATABASES_TOML"; then
    log_error "The app reported the reset but $DATABASES_TOML still holds the entry"
    cat "$DATABASES_TOML"
    exit 1
fi
log_success "The database entry is gone from the configured list"

if vault_has_secret "$TMP_DIR/vault" test-secret; then
    log_error "The app reported the reset but the vault still holds 'test-secret'"
    exit 1
fi
log_success "The secret is gone from the vault"

if [ -d "$TMP_DIR/config" ] && [ -n "$(ls -A "$TMP_DIR/config" 2>/dev/null)" ]; then
    log_error "The app reported the reset but its config directory still holds files"
    ls -la "$TMP_DIR/config"
    exit 1
fi
log_success "The app's config directory has been emptied"

if [ -d "$CACHE_DIR" ] && [ -n "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
    log_error "The app reported the reset but its cache directory still holds files"
    ls -la "$CACHE_DIR"
    exit 1
fi
log_success "The app's cache directory has been emptied"

# The whole point of the desktop half of this feature: the database is the user's, it lives where
# they put it, and the reset must not have touched a byte of it.
if [ ! -d "$TMP_DIR/test-db" ]; then
    log_error "The reset DELETED the user's database directory at $TMP_DIR/test-db"
    exit 1
fi
if [ ! -f "$TMP_DIR/test-db/.db/files.dat" ]; then
    log_error "The reset removed files from the user's database at $TMP_DIR/test-db"
    ls -la "$TMP_DIR/test-db" "$TMP_DIR/test-db/.db" 2>/dev/null
    exit 1
fi
if [ -z "$(find "$TMP_DIR/test-db/asset" -type f 2>/dev/null | head -n1)" ]; then
    log_error "The reset deleted the photo imported into the user's database at $TMP_DIR/test-db"
    find "$TMP_DIR/test-db" -maxdepth 2 2>/dev/null
    exit 1
fi
log_success "The user's database on disk, and the photo in it, were left alone"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 37 passed: reset-device"
