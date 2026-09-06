#!/bin/bash

# The database named by last_database in databases.toml is reopened on launch, and a config that
# names none leaves the app on the welcome screen.
#
# On mobile this used to be kept in the WebView's local storage, which nothing outside the WebView can
# write, so it could not be seeded from the host and the app never reopened anything. It is in
# databases.toml now, which the harness already writes from outside the app, so `bun run and50` and
# these tests can both land straight in a seeded database.
#
# Three things are covered, in one launch each:
#   1. A seeded config naming a database opens it with nothing tapped.
#   2. A seeded config naming none stays on the welcome screen, which is what the tests that seed a
#      database list without a last database rely on.
#   3. Opening a database from the app records it, so the next launch reopens it by itself.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 53 "reopen-last-database"

# The fixture's sandbox-relative name, under the app's private storage. On mobile a database path is
# a bare name relative to that sandbox, which is the same value the config entry's path field holds.
DB_NAME="50-assets"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Start from nothing on the device: no databases, no settings, nothing left by another test. The
# config this test seeds is the whole of the state it depends on.
"${PLATFORM}_reset_app_state" || exit 1

"${PLATFORM}_seed_database" "$REPO_DIR/test/dbs/$DB_NAME" "$DB_NAME" || exit 1

# --- 1. A config naming a last database opens it on launch. ---

# Seeded before the app starts, because the app reads this file once as it comes up.
"${PLATFORM}_seed_databases_config" \
    "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]" \
    "[\"$DB_NAME\"]" \
    "$DB_NAME" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Nothing in this test taps anything, so the gallery filling can only have come from last_database.
wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1
log_success "The seeded database opened on launch with nothing tapped"

stop_app "$APP_PORT" "$TMP_DIR"

# --- 2. A config naming no last database stays on the welcome screen. ---

# This is the default every other mobile test seeds, so a change here would silently start opening a
# database in tests that expect nothing open.
"${PLATFORM}_seed_databases_config" \
    "[{\"name\":\"$DB_NAME\",\"path\":\"$DB_NAME\"}]" \
    "[\"$DB_NAME\"]" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_value "$APP_PORT" "no-database-loaded" "." || exit 1
log_success "A config naming no last database left the app on the welcome screen"

# --- 3. Opening a database records it, so the next launch reopens it. ---

# Opened from the sidebar rather than with the open-database command, because that command dispatches
# the database-opened event straight to its subscribers and never reaches notifyDatabaseOpened, which
# is what records the path. A test driving the shortcut would pass while the real path was broken.
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
wait_for_value "$APP_PORT" "open-recent-database-button-0" "." || exit 1
send_command "$APP_PORT" click '{"dataId":"open-recent-database-button-0"}' || exit 1
wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1

# The path is written to databases.toml through the embedded worker after the gallery has already
# filled, so the file is read back rather than assumed: this is the write the restart below depends
# on, and waiting for the gallery does not mean it has landed.
last_database_recorded=false
for _attempt in $(seq 1 60); do
    if "${PLATFORM}_read_databases_config" | grep -q "last_database"; then
        last_database_recorded=true
        break
    fi
    sleep 1
done

if [ "$last_database_recorded" != "true" ]; then
    log_error "Opening a database did not record it in databases.toml:"
    "${PLATFORM}_read_databases_config"
    exit 1
fi

stop_app "$APP_PORT" "$TMP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1
log_success "The database opened in the app was reopened on the next launch"

check_no_errors "$TMP_DIR" || exit 1

log_success "Test 53 passed: reopen-last-database"
