#!/bin/bash

# Mobile port of desktop 17-replicate-database. Registers a source database and replicates it
# (partial then full). Desktop pre-creates the source database with the CLI and verifies the
# replica files on the host filesystem; on mobile both the source and the replica live on the
# device, so this port drives the UI flow and surfaces where database registration/replication
# is missing. Host-side file assertions are dropped (they cannot see device storage).

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "replicate-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, then create an empty source database (under tmp) and copy it into the sandbox
# (adding it auto-opens it). Also clear any replica from a previous run so the destination starts
# empty (replicating onto an unrelated existing database is refused without --force).
send_command "$APP_PORT" reset-config '{}' || exit 1
"${PLATFORM}_reset_path" "dest-partial"
create_database "$TMP_DIR/source-db"
"${PLATFORM}_seed_database" "$TMP_DIR/source-db" "source-db"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"source-db"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added" 20

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replicate database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
wait_for_log "$TMP_DIR" "Replication completed for" 30

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: replicate-database"
