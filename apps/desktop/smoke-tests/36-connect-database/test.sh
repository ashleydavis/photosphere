#!/bin/bash

# Exercises "Connect to remote" from Manage Databases against a remote that already holds a
# different database, and the rule that only one database can be the default.
#
# Sync refuses two databases that are not related to each other, and this feature does not weaken
# that: connecting is the separate, explicit operation that makes them related. The two databases
# here are created independently, so they start out unrelated, and both hold the same photo, so the
# test can tell whether shared content is uploaded twice.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 36 "connect-database"

LOCAL_DB="$TMP_DIR/local-db"
REMOTE_DB="$TMP_DIR/remote-db"
SECOND_DB="$TMP_DIR/second-db"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

#
# Counts the originals in a database.
#
count_originals() {
    ls -1 "$1/asset" 2>/dev/null | wc -l | tr -d ' '
}

log_info "Pre-creating the databases with the CLI..."
cd "$CLI_DIR" || exit 1
bun run start -- init --db "$LOCAL_DB" --yes || exit 1
bun run start -- init --db "$REMOTE_DB" --yes || exit 1
bun run start -- init --db "$SECOND_DB" --yes || exit 1

# The same photo goes into both, so connecting has something it must not upload twice. Each of them
# also has one of its own.
bun run start -- add --db "$LOCAL_DB" "$REPO_DIR/test/test.png" --yes || exit 1
bun run start -- add --db "$REMOTE_DB" "$REPO_DIR/test/test.png" --yes || exit 1
bun run start -- add --db "$LOCAL_DB" "$REPO_DIR/test/test.jpg" --yes || exit 1
bun run start -- add --db "$REMOTE_DB" "$REPO_DIR/test/test.webp" --yes || exit 1
cd "$DESKTOP_DIR" || exit 1

REMOTE_BEFORE=$(count_originals "$REMOTE_DB")
if [ "$REMOTE_BEFORE" -ne 2 ]; then
    log_error "Expected the remote to start with 2 originals, found $REMOTE_BEFORE"
    exit 1
fi

# Both databases are listed before the app starts. Adding them through the dialog opens each one as
# it is added, which takes the page away and makes the second add a race; the list is not what this
# test is about, so it is seeded through the same writer the app itself uses.
mkdir -p "$TMP_DIR/config"
DATABASES="[{\"name\":\"Local\",\"description\":\"\",\"path\":\"$LOCAL_DB\"},{\"name\":\"Second\",\"description\":\"\",\"path\":\"$SECOND_DB\"}]" \
    RECENT="[]" \
    bun "$REPO_DIR/apps/smoke-tests/lib/write-databases-config.ts" "$TMP_DIR/config/databases.toml" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"

# --- Only one database can be the default. ---

send_command "$APP_PORT" click '{"dataId":"set-default-database-button","nth":0}'
wait_for_log "$TMP_DIR" "Default database set"
wait_for_value "$APP_PORT" "database-default-badge-0" "Default"
log_success "The first database is the default"

send_command "$APP_PORT" click '{"dataId":"set-default-database-button","nth":1}'
wait_for_log "$TMP_DIR" "Default database set"
wait_for_value "$APP_PORT" "database-default-badge-1" "Default"

# The first row's badge has to be gone. Two at once would mean the app believes photos are being
# backed up to two places while only one of them is really receiving them.
FIRST_BADGE=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=database-default-badge-0" 2>/dev/null || true)
if echo "$FIRST_BADGE" | grep -q "Default"; then
    log_error "Two databases are marked as the default at once"
    exit 1
fi
log_success "Making a second database the default cleared the first"

# --- Connect the local database to the unrelated remote. ---

send_command "$APP_PORT" click '{"dataId":"connect-database-button","nth":0}'
wait_for_log "$TMP_DIR" "Connect to remote dialog opened"

send_command "$APP_PORT" type "{\"dataId\":\"connect-remote-path-input\",\"text\":\"$REMOTE_DB\"}"
send_command "$APP_PORT" click '{"dataId":"connect-database-confirm"}'

wait_for_log "$TMP_DIR" "Connected to remote" 120
wait_for_value "$APP_PORT" "connect-database-success" "Photos uploaded: 1"
log_success "One photo was uploaded and the shared one was recognised"

send_command "$APP_PORT" click '{"dataId":"connect-database-close"}'

# The remote holds three originals: its own two plus the one that was only on the local side. The
# photo both had is there once, not twice.
REMOTE_AFTER=$(count_originals "$REMOTE_DB")
if [ "$REMOTE_AFTER" -ne 3 ]; then
    log_error "Expected the remote to hold 3 originals after connecting, found $REMOTE_AFTER"
    ls -la "$REMOTE_DB/asset" 2>/dev/null || true
    exit 1
fi
log_success "The remote holds three originals, with the shared photo only once"

# --- Sync works now, where it refused before. ---

cd "$CLI_DIR" || exit 1
bun run start -- verify --db "$REMOTE_DB" --yes || exit 1
bun run start -- sync --db "$LOCAL_DB" --yes || exit 1
cd "$DESKTOP_DIR" || exit 1
log_success "Ordinary sync works after connecting"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 36 passed: connect-database"
