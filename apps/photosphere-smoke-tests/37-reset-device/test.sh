#!/bin/bash

# Exercises "Reset device" on the Configuration dialog: both cancels leave everything in place, and confirming both steps empties the
# database list, the vault and the app's own storage.
#
# The assertion that matters most differs by platform. On a desktop a database sits wherever the user put it and may be the only copy
# of their photos, so the reset must forget the entry and leave every file of it alone: the database is created outside the app's
# config directory, exactly as a user does, and checked to still be there afterwards. On a phone every local database lives inside the
# app's storage, so clearing that storage is what takes the databases off the device: the last assertions read the storage back to
# prove the database directory really went, rather than trusting a log line or an empty-looking list.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 37 "reset-device"

trap 'cleanup_apps "$TMP_DIR"' EXIT

IMAGES_DIR="$REPO_DIR/test/multiple-files"

case "$PLATFORM" in
    android|ios)
        # Wipe everything the app has stored on the device before launch, with the app stopped, so nothing can write state back
        # underneath it and the test starts from a known state.
        "${PLATFORM}_reset_app_state" || exit 1
        DATABASE_PATH="$("${PLATFORM}_app_path" "test-db")"
        ;;
    *)
        DATABASE_PATH="$TMP_DIR/test-db"
        # Where the app keeps what it works out about a database (the hash cache, the import record). The platform library gives it
        # to the app inside the scenario directory, and the reset empties it along with the config.
        CACHE_DIR="$TMP_DIR/cache"
        ;;
esac

#
# Fails the test when the database entry or the secret is not where it should be. Used after each cancel: a cancel that removed
# anything is the worst failure this feature can have.
# Usage: require_state_intact <what-was-cancelled>
#
require_state_intact() {
    local moment="$1"
    case "$PLATFORM" in
        android|ios)
            if ! "${PLATFORM}_path_exists" "test-db"; then
                log_error "$moment deleted the database from the app's storage"
                exit 1
            fi
            ;;
        *)
            if ! read_config_file databases.toml | grep -q 'My Test DB'; then
                log_error "$moment removed the database entry from databases.toml"
                read_config_file databases.toml
                exit 1
            fi
            if ! vault_has_secret "$TMP_DIR/vault" test-secret; then
                log_error "$moment deleted the secret from the vault"
                exit 1
            fi
            ;;
    esac
    if [ -z "$(read_config_file databases.toml)" ]; then
        log_error "$moment deleted the app's databases.toml"
        exit 1
    fi
    send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
    wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"
    log_success "$moment left the database and the secret in place"
}

#
# Opens the Configuration dialog and the reset confirmation on its first step.
#
open_reset_dialog() {
    click_sidebar_item "$APP_PORT" configuration || exit 1
    wait_for_value "$APP_PORT" "configuration-dialog" "Reset device"
    send_command "$APP_PORT" click '{"dataId":"reset-device-open"}' || exit 1
    wait_for_value "$APP_PORT" "reset-device-dialog" "cannot be undone"
}

case "$PLATFORM" in
    android|ios)
        ;;
    *)
        log_info "Pre-creating database with the CLI..."
        create_database "$DATABASE_PATH"
        ;;
esac

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# A database entry and a secret, added the way a user adds them, so the reset has something real to remove.
case "$PLATFORM" in
    android|ios)
        click_sidebar_item "$APP_PORT" new-database || exit 1
        wait_for_log "$TMP_DIR" "Create database dialog opened"
        send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"test-db"}' || exit 1
        send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"create-database-confirm"}' || exit 1
        wait_for_log "$TMP_DIR" "Database created"

        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        add_secret_via_ui "$APP_PORT" "test-secret" "s3-credentials" "us-east-1" || exit 1
        wait_for_value "$APP_PORT" "secret-row-name-test-secret" "test-secret"
        ;;
    *)
        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"
        send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Add database dialog opened"
        send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
        send_command "$APP_PORT" type "$(jq -cn --arg text "$DATABASE_PATH" '{dataId: "database-path-input", text: $text}')" || exit 1
        send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
        wait_for_log "$TMP_DIR" "Database entry added"

        # One photo imported into it, so the database on disk has something to lose and the app has written a real hash cache and
        # import record into its cache directory for the reset to clear.
        click_sidebar_item "$APP_PORT" open-database || exit 1
        wait_for_log "$TMP_DIR" "Open database dialog opened"
        send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
        wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
        send_command "$APP_PORT" navigate '{"page":"/"}' || exit 1
        wait_for_log "$TMP_DIR" "Gallery loaded: 0 assets"
        send_command "$APP_PORT" click '{"dataId":"import-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Import page ready"
        send_command "$APP_PORT" drop "$(jq -cn --arg path "$IMAGES_DIR/test-1.jpeg" '{dataId: "import-drop-zone", paths: [$path]}')" || exit 1
        wait_for_log "$TMP_DIR" "1 assets imported"

        if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
            log_error "The import wrote nothing into $CACHE_DIR, so this test cannot show the reset clears it"
            exit 1
        fi
        log_success "The import left the app something to clear in its cache directory"

        send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
        wait_for_log "$TMP_DIR" "Secrets page loaded"
        send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
        wait_for_log "$TMP_DIR" "Add secret dialog opened"
        send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}' || exit 1
        send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
        wait_for_log "$TMP_DIR" "Secret added"
        ;;
esac

require_state_intact "Setting up"

# Cancelling on the first step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-cancel"}' || exit 1
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "cannot be undone" || exit 1
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1
require_state_intact "Cancelling on the first step"

# Cancelling on the final step.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}' || exit 1
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-final-cancel"}' || exit 1
wait_for_value_gone "$APP_PORT" "reset-device-dialog" "Last chance" || exit 1
send_command "$APP_PORT" click '{"dataId":"configuration-dialog-close"}' || exit 1
require_state_intact "Cancelling on the final step"

# Confirming both steps.
open_reset_dialog
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}' || exit 1
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Device reset:"

# The log line alone proves nothing: it is written straight after the reset returns, so a reset that removed nothing leaves it intact.
# Every assertion below reads the state back.
case "$PLATFORM" in
    android|ios)
        # Already on the Secrets page, which the reset's refresh re-rendered, so the row is watched where it is rather than navigated
        # to again (navigating to the page already showing logs nothing to wait on).
        wait_for_value_gone "$APP_PORT" "secret-row-name-test-secret" "test-secret" || exit 1
        log_success "The secret is gone from the keychain"

        send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
        wait_for_log "$TMP_DIR" "Databases page loaded"
        wait_for_value_gone "$APP_PORT" "database-row-name-test-db" "test-db" || exit 1
        log_success "The database is gone from the list"

        if "${PLATFORM}_path_exists" "test-db"; then
            log_error "The app reported the reset but the database is still in its storage sandbox"
            exit 1
        fi
        log_success "The database's files are gone from the device"

        # The settings the user chose are in config.yaml beside the databases list, so a reset that left them behind would hand the
        # next person the previous owner's settings. state.yaml holds what the app remembered: the folders it last opened at, how the
        # gallery was sorted, and the news it had already shown.
        for config_file in databases.toml config.yaml state.yaml; do
            if [ -n "$(read_config_file "$config_file")" ]; then
                log_error "The app reported the reset but $config_file is still in the app's storage"
                exit 1
            fi
        done
        log_success "The app's database list, settings and remembered state are gone from the device"
        ;;
    *)
        if read_config_file databases.toml | grep -q 'My Test DB'; then
            log_error "The app reported the reset but databases.toml still holds the entry"
            read_config_file databases.toml
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

        # The whole point of the desktop half of this feature: the database is the user's, it lives where they put it, and the reset
        # must not have touched a byte of it.
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
        ;;
esac

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 37 passed: reset-device"
