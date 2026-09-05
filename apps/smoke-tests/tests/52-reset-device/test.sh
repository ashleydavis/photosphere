#!/bin/bash

# Mobile counterpart of desktop 37-reset-device. Creates a database in the app's storage sandbox and
# a secret in the keychain, then drives "Reset device" from the settings dialog: both cancels leave
# everything in place, and confirming both steps empties the database list, the secrets list and the
# storage sandbox.
#
# This is where the feature does the most: on a phone every local database lives inside the app's
# storage, so clearing that storage is what takes the databases off the device. The last assertion
# reads the sandbox back to prove the database directory really went, rather than trusting a log line
# or an empty-looking list.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 52 "reset-device"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

#
# Fails the test when the database or the secret is not where it should be. Used after each cancel: a
# cancel that removed anything is the worst failure this feature can have.
# Usage: require_state_intact <what-was-cancelled>
#
require_state_intact() {
    local moment="$1"
    if ! "${PLATFORM}_sandbox_path_exists" "test-db"; then
        log_error "$moment deleted the database from the app's storage"
        exit 1
    fi
    if ! "${PLATFORM}_sandbox_path_exists" "databases.toml"; then
        log_error "$moment deleted the app's databases.toml"
        exit 1
    fi
    send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
    wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"
    log_success "$moment left the database and the secret in place"
}

#
# Opens the settings dialog and the reset confirmation on its first step.
#
open_reset_dialog() {
    send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
    wait_for_value "$APP_PORT" "configuration-dialog" "Reset device"
    send_command "$APP_PORT" click '{"dataId":"reset-device-open"}' || exit 1
    wait_for_value "$APP_PORT" "reset-device-dialog" "cannot be undone"
}

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# A database and a secret, made the way a user makes them, so the reset has something real to remove.
send_command "$APP_PORT" menu '{"itemId":"new-database"}' || exit 1
wait_for_log "$TMP_DIR" "Create database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"test-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database created"

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"
add_secret_via_ui "$APP_PORT" "test-secret" "s3-credentials" "us-east-1" || exit 1
wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"

require_state_intact "Setting up"

# Cancelling on the first step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-cancel"}' || exit 1
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "cannot be undone"
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1
require_state_intact "Cancelling on the first step"

# Cancelling on the final step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}' || exit 1
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-final-cancel"}' || exit 1
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1
require_state_intact "Cancelling on the final step"

# Confirming both steps.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}' || exit 1
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Device reset:"

# The log line alone proves nothing: it is written straight after the reset returns, so a reset that
# removed nothing leaves it intact. Every assertion below reads the state back.
# Already on the Secrets page, which the reset's refresh re-rendered, so the row is watched where it
# is rather than navigated to again (navigating to the page already showing logs nothing to wait on).
wait_for_value_gone "$APP_PORT" "secret-row-name-test-secret" "test-secret"
log_success "The secret is gone from the keychain"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"
wait_for_value_gone "$APP_PORT" "database-row-name-test-db" "test-db"
log_success "The database is gone from the list"

if "${PLATFORM}_sandbox_path_exists" "test-db"; then
    log_error "The app reported the reset but the database is still in its storage sandbox"
    exit 1
fi
log_success "The database's files are gone from the device"

if "${PLATFORM}_sandbox_path_exists" "databases.toml"; then
    log_error "The app reported the reset but its databases.toml is still in the storage sandbox"
    exit 1
fi
log_success "The app's config is gone from the device"

check_no_errors "$TMP_DIR"

log_success "Test 52 passed: reset-device"
