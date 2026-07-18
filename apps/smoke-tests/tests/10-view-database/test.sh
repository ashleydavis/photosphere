#!/bin/bash

# Adds a database entry with a geocoding secret, then views the database and reveals the secret.
# Electron pre-creates the DB and api-key via the CLI into the app vault. Mobile seeds both
# via create_database / seed_database / seed-secrets.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 10 "view-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating database with CLI..."
    create_database "$TMP_DIR/test-db"

    log_info "Pre-creating api-key secret with CLI (using the same vault as the app)..."
    mkdir -p "$TMP_DIR/config" "$TMP_DIR/vault"
    (
        cd "$REPO_DIR/apps/cli"
        PHOTOSPHERE_CONFIG_DIR="$TMP_DIR/config" \
        PHOTOSPHERE_VAULT_DIR="$TMP_DIR/vault" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        bun run start -- secrets add --yes --type api-key --name smoke-geocoding --value "fake-geocoding-key"
    ) >/dev/null 2>&1

    DB_PATH="$TMP_DIR/test-db"
else
    DB_PATH="test-db"
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/test-db"
    seed_database "$TMP_DIR/test-db" "test-db"
    send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"geo-key","type":"api-key"},"value":"the-geocoding-key"}]}' || exit 1
fi

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_PATH\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"select-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "Select secret modal ready"

send_command "$APP_PORT" click '{"dataId":"secret-select-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
fi
send_command "$APP_PORT" click '{"dataId":"view-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "View database dialog opened"

send_command "$APP_PORT" click '{"dataId":"view-secret-geocoding-button"}' || exit 1
wait_for_log "$TMP_DIR" "View secret dialog opened"

send_command "$APP_PORT" click '{"dataId":"reveal-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret revealed"

check_no_errors "$TMP_DIR"

log_success "Test 10 passed: view-database"
