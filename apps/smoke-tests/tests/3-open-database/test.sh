#!/bin/bash

# Opens a configured database from the open-database dialog.
# Electron pre-creates the DB with the CLI and writes databases.toml on the host.
# Mobile seeds the fixture into the sandbox and seed-databases into WebView storage.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 3 "open-database"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating database with CLI..."
    create_database "$TMP_DIR/test-db"

    log_info "Writing databases.toml with one entry..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
EOF
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    seed_database "$REPO_DIR/test/dbs/50-assets" "$DB_NAME"
    send_command "$APP_PORT" seed-databases "{\"databases\":[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]}" || exit 1
fi

send_command "$APP_PORT" menu '{"itemId":"open-database"}' || exit 1
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}' || exit 1
wait_for_log "$TMP_DIR" "Database opened"

if [ "$PLATFORM" = "electron" ]; then
    check_no_errors "$TMP_DIR"
else
    check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error' || exit 1
fi

log_success "Test 3 passed: open-database"
