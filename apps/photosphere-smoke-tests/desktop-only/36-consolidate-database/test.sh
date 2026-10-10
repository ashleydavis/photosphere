#!/bin/bash

# Exercises "Consolidate into remote" from Manage Databases against a remote that already holds a different database, and the rule that
# only one database can be the default.
#
# Sync refuses two databases that are not related to each other, and this feature does not weaken that: consolidating is the separate,
# explicit operation that makes them related. The two databases here are created independently, so they start out unrelated, and both
# hold the same photo, so the test can tell whether shared content is uploaded twice.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

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

# Both databases are listed before the app starts. Adding them through the dialog opens each one as it is added, which takes the page
# away and makes the second add a race; the list is not what this test is about, so it is written to the config file.
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<TOML
[[databases]]
name = "Local"
description = ""
path = "$LOCAL_DB"

[[databases]]
name = "Second"
description = ""
path = "$SECOND_DB"
TOML

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# --- Only one database can be the default. ---

send_command "$APP_PORT" click '{"dataId":"set-default-database-button","nth":0}' || exit 1
wait_for_log "$TMP_DIR" "Default database set"
wait_for_value "$APP_PORT" "database-default-badge-0" "Default"
log_success "The first database is the default"

send_command "$APP_PORT" click '{"dataId":"set-default-database-button","nth":1}' || exit 1
wait_for_log "$TMP_DIR" "Default database set"
wait_for_value "$APP_PORT" "database-default-badge-1" "Default"

# The first row's badge has to be gone. Two at once would mean the app believes photos are being backed up to two places while only one
# of them is really receiving them.
FIRST_BADGE="$(read_value "$APP_PORT" "database-default-badge-0")"
if printf '%s' "$FIRST_BADGE" | grep -q "Default"; then
    log_error "Two databases are marked as the default at once"
    exit 1
fi
log_success "Making a second database the default cleared the first"

# --- Consolidate the local database into the unrelated remote. ---

send_command "$APP_PORT" click '{"dataId":"consolidate-database-button","nth":0}' || exit 1
wait_for_log "$TMP_DIR" "Consolidate into remote dialog opened"

send_command "$APP_PORT" type "$(jq -cn --arg text "$REMOTE_DB" '{dataId: "consolidate-remote-path-input", text: $text}')" || exit 1
send_command "$APP_PORT" click '{"dataId":"consolidate-database-confirm"}' || exit 1

wait_for_log "$TMP_DIR" "Consolidated into remote" 120
wait_for_value "$APP_PORT" "consolidate-database-success" "Photos uploaded: 1"
log_success "One photo was uploaded and the shared one was recognised"

send_command "$APP_PORT" click '{"dataId":"consolidate-database-close"}' || exit 1

# The remote holds three originals: its own two plus the one that was only on the local side. The photo both had is there once, not twice.
REMOTE_AFTER="$(count_originals "$REMOTE_DB")"
if [ "$REMOTE_AFTER" -ne 3 ]; then
    log_error "Expected the remote to hold 3 originals after consolidating, found $REMOTE_AFTER"
    ls -la "$REMOTE_DB/asset" 2>/dev/null || true
    exit 1
fi
log_success "The remote holds three originals, with the shared photo only once"

# --- Sync works now, where it refused before. ---

if ! run_cli "$TMP_DIR" verify --db "$REMOTE_DB" --yes; then
    log_error "Verifying the remote after consolidating failed"
    exit 1
fi
if ! run_cli "$TMP_DIR" sync --db "$LOCAL_DB" --yes; then
    log_error "Syncing the local database after consolidating failed"
    exit 1
fi
log_success "Ordinary sync works after consolidating"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 36 passed: consolidate-database"
