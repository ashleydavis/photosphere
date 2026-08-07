#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 6 "add-database-entry"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
}
trap cleanup EXIT

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes || exit 1
cd "$DESKTOP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}'

wait_for_log "$TMP_DIR" "Databases page loaded"

send_command "$APP_PORT" click '{"dataId":"add-database-button"}'

wait_for_log "$TMP_DIR" "Add database dialog opened"

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'

send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"

send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'

wait_for_log "$TMP_DIR" "Database entry added"

# The log line alone proved nothing: the main process writes it straight after awaiting
# addDatabaseEntry, so an entry that never reaches databases.toml leaves it intact and this test
# passed with nothing registered. Confirmed by dropping the addDatabaseEntry call and watching this
# test still pass. Reading the file back is the assertion that the entry was really added.
DATABASES_TOML="$TMP_DIR/config/databases.toml"
if [ ! -f "$DATABASES_TOML" ]; then
    log_error "The app reported 'Database entry added' but wrote no $DATABASES_TOML"
    exit 1
fi
if ! grep -q 'My Test DB' "$DATABASES_TOML"; then
    log_error "The app reported 'Database entry added' but $DATABASES_TOML has no entry named 'My Test DB'"
    cat "$DATABASES_TOML"
    exit 1
fi
log_success "The database entry is in databases.toml"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 6 passed: add-database-entry"
