#!/bin/bash

# Exercises "Consolidate into remote" from Manage Databases against a remote that already holds a different database, and the rule that
# only one database can be the default.
#
# Sync refuses two databases that are not related to each other, and this feature does not weaken that: consolidating is the separate,
# explicit operation that makes them related. The two databases here are created independently, so they start out unrelated, and both
# hold the same photo, so the test can tell whether shared content is uploaded twice.
#
# The databases live in the app's own storage, and the app is what consolidates them. What it left behind is read by copying the
# databases out to the host and reading the copies with the CLI.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 36 "consolidate-database"

trap 'cleanup_apps "$TMP_DIR"' EXIT

LOCAL_DB="$TMP_DIR/local-db"
REMOTE_DB="$TMP_DIR/remote-db"
SECOND_DB="$TMP_DIR/second-db"

#
# Counts the originals in a database.
#
count_originals() {
    ls -1 "$1/asset" 2>/dev/null | wc -l | tr -d ' '
}

# The same photo goes into both the local and the remote database, so consolidating has something it must not upload twice. Each of
# them also has one of its own.
log_info "Pre-creating the databases with the CLI..."
create_database "$LOCAL_DB" "$REPO_DIR/test/test.png" "$REPO_DIR/test/test.jpg"
create_database "$REMOTE_DB" "$REPO_DIR/test/test.png" "$REPO_DIR/test/test.webp"
create_database "$SECOND_DB"

REMOTE_BEFORE="$(count_originals "$REMOTE_DB")"
if [ "$REMOTE_BEFORE" -ne 2 ]; then
    log_error "Expected the remote to start with 2 originals, found $REMOTE_BEFORE"
    exit 1
fi

# Wipe everything the app has stored, with the app stopped, so the test starts from a known state.
"${PLATFORM}_reset_app_state" || exit 1

# The databases go into the app's storage, where the app reads and consolidates them.
"${PLATFORM}_seed_database" "$LOCAL_DB" "local-db" || exit 1
"${PLATFORM}_seed_database" "$REMOTE_DB" "remote-db" || exit 1
"${PLATFORM}_seed_database" "$SECOND_DB" "second-db" || exit 1
LOCAL_APP_PATH="$("${PLATFORM}_app_path" "local-db")"
REMOTE_APP_PATH="$("${PLATFORM}_app_path" "remote-db")"
SECOND_APP_PATH="$("${PLATFORM}_app_path" "second-db")"

# Both databases are listed before the app starts. Adding them through the dialog opens each one as it is added, which takes the page
# away and makes the second add a race; the list is not what this test is about, so it is written to the config file.
"${PLATFORM}_seed_databases_config" "$(jq -cn --arg local "$LOCAL_APP_PATH" --arg second "$SECOND_APP_PATH" '[{name: "Local", path: $local}, {name: "Second", path: $second}]')" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# --- Only one database can be the default. ---

click_database_row_action "$APP_PORT" 0 set-default-database-button || exit 1
wait_for_log "$TMP_DIR" "Default database set"
expect_default_database "$APP_PORT" 0 2 "$LOCAL_APP_PATH"
log_success "The first database is the default"

click_database_row_action "$APP_PORT" 1 set-default-database-button || exit 1
wait_for_log "$TMP_DIR" "Default database set"
expect_default_database "$APP_PORT" 1 2 "$SECOND_APP_PATH"
log_success "Making a second database the default cleared the first"

# --- Consolidate the local database into the unrelated remote. ---

click_database_row_action "$APP_PORT" 0 consolidate-database-button || exit 1
wait_for_log "$TMP_DIR" "Consolidate into remote dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$REMOTE_APP_PATH" '{dataId: "consolidate-remote-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"consolidate-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Consolidated into remote" 120
wait_for_value "$APP_PORT" "consolidate-database-success" "Photos uploaded: 1"
log_success "One photo was uploaded and the shared one was recognised"

send_command "$APP_PORT" click '{"dataId":"consolidate-database-close"}' || exit 1

# What the app left behind, copied out to the host to be read.
FETCHED_REMOTE="$TMP_DIR/fetched-remote"
FETCHED_LOCAL="$TMP_DIR/fetched-local"
fetch_app_database "remote-db" "$FETCHED_REMOTE" || exit 1
fetch_app_database "local-db" "$FETCHED_LOCAL" || exit 1

# The remote holds three originals: its own two plus the one that was only on the local side. The photo both had is there once, not twice.
REMOTE_AFTER="$(count_originals "$FETCHED_REMOTE")"
if [ "$REMOTE_AFTER" -ne 3 ]; then
    log_error "Expected the remote to hold 3 originals after consolidating, found $REMOTE_AFTER"
    ls -la "$FETCHED_REMOTE/asset" 2>/dev/null || true
    exit 1
fi
log_success "The remote holds three originals, with the shared photo only once"

# --- Sync works now, where it refused before. ---

# The local database now names the remote as its origin, by the path the app was given. The copy of it on the host is pointed at the
# copy of the remote on the host, because the app's path means nothing there; nothing else about it changes.
RECORDED_ORIGIN="$(jq -r '.origin' "$FETCHED_LOCAL/.db/config.json")"
if [ "$RECORDED_ORIGIN" != "$REMOTE_APP_PATH" ]; then
    log_error "Expected the local database to record $REMOTE_APP_PATH as its origin, found: $RECORDED_ORIGIN"
    exit 1
fi
jq --arg origin "$FETCHED_REMOTE" '.origin = $origin' "$FETCHED_LOCAL/.db/config.json" > "$TMP_DIR/local-config.json" || exit 1
cp "$TMP_DIR/local-config.json" "$FETCHED_LOCAL/.db/config.json" || exit 1

if ! run_zig_cli "$TMP_DIR" verify --db "$FETCHED_REMOTE" --yes; then
    log_error "Verifying the remote after consolidating failed"
    exit 1
fi
if ! run_zig_cli "$TMP_DIR" sync --db "$FETCHED_LOCAL" --yes; then
    log_error "Syncing the local database after consolidating failed"
    exit 1
fi
log_success "Ordinary sync works after consolidating"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 36 passed: consolidate-database"
