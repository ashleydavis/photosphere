#!/bin/bash
DESCRIPTION="The import record remembers what a database took in, badges manual and automatic apart, and never travels to another database"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-87}"
print_test_header "$TEST_NUMBER" "IMPORT RECORD"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
LOCAL_DB="$TEST_DIR/local-db"
REMOTE_DB="$TEST_DIR/remote-db"
REPLICA_DB="$TEST_DIR/replica-db"
WATCH_DIR="$TEST_DIR/photos"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

RECORD_FILE="$LOCAL_DB/.db/imports.dat"

invoke_command "Initialize the local database" "$CLI_COMMAND init --db $LOCAL_DB --yes"

# --- 1. A manual import is recorded, and badged as manual. ---

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/asked-for.png"
invoke_command "Import a photo by hand" "$CLI_COMMAND add --db $LOCAL_DB $WATCH_DIR/asked-for.png --yes"

if [ ! -f "$RECORD_FILE" ]; then
    log_error "No import record was written at $RECORD_FILE"
    exit 1
fi
log_success "The import was recorded"

if ! grep -q '"logicalPath":"[^"]*asked-for.png"' "$RECORD_FILE"; then
    log_error "The record does not name the photo that was imported"
    exit 1
fi
if ! grep -q '"source":"manual"' "$RECORD_FILE"; then
    log_error "The record does not say the user asked for that import"
    exit 1
fi
log_success "The manual import is recorded and badged manual"

# --- 2. An automatic import is recorded too, and badged automatic. ---

# Only a watch badges what it takes in as automatic, and a watch does not end by itself, so this
# starts one, waits for the photo to land, and stops it with Ctrl-C. That is what a watch is: there
# is no bounded version of it to run instead.
WATCH_LOG="$TEST_DIR/watch.log"
set -m
env NODE_ENV=testing $CLI_COMMAND add --db "$LOCAL_DB" "$WATCH_DIR" --watch --yes > "$WATCH_LOG" 2>&1 &
WATCH_PGID=$!
set +m

cp "$TEST_FILES_DIR/test.jpg" "$WATCH_DIR/arrived.jpg"

for attempt in $(seq 1 60); do
    sleep 1
    if grep -q '"logicalPath":"[^"]*arrived.jpg"' "$RECORD_FILE" 2>/dev/null; then
        break
    fi
done

kill -INT -"$WATCH_PGID" 2>/dev/null || true
for attempt in $(seq 1 60); do
    sleep 0.5
    if ! kill -0 "$WATCH_PGID" 2>/dev/null; then
        break
    fi
done

if ! grep -q '"source":"automatic"' "$RECORD_FILE"; then
    log_error "An automatically imported photo was not badged automatic"
    exit 1
fi
if ! grep -q '"logicalPath":"[^"]*arrived.jpg"' "$RECORD_FILE"; then
    log_error "The record does not name the photo automatic import took in"
    exit 1
fi
log_success "The automatic import is recorded and badged automatic"

# Both are in the one record: a user asking what came in should not have to look in two places.
if ! grep -q '"source":"manual"' "$RECORD_FILE"; then
    log_error "The manual import was lost when the automatic one was recorded"
    exit 1
fi
log_success "Manual and automatic imports are in the same record"

# --- 3. The record must not travel. It is this machine's account of what it did. ---

invoke_command "Create the remote and consolidate into it" "$CLI_COMMAND consolidate --db $LOCAL_DB $REMOTE_DB --yes"

if [ -f "$REMOTE_DB/.db/imports.dat" ]; then
    log_error "Consolidating copied the import record to the remote. It must not travel: it would show this machine's imports as the remote's."
    exit 1
fi
log_success "Consolidation left the import record behind"

invoke_command "Sync to the remote" "$CLI_COMMAND sync --db $LOCAL_DB --yes"

if [ -f "$REMOTE_DB/.db/imports.dat" ]; then
    log_error "Sync copied the import record to the remote"
    exit 1
fi
log_success "Sync left the import record behind"

invoke_command "Replicate to a third database" "$CLI_COMMAND replicate --db $LOCAL_DB --dest $REPLICA_DB --yes"

if [ -f "$REPLICA_DB/.db/imports.dat" ]; then
    log_error "Replication copied the import record to the replica"
    exit 1
fi
log_success "Replication left the import record behind"

# --- 4. The photos themselves did travel, so the checks above prove exclusion, not a failed copy. ---

REPLICA_SUMMARY=""
invoke_command "Summarise the replica" "$CLI_COMMAND summary --db $REPLICA_DB --yes" 0 REPLICA_SUMMARY
expect_output_value "$REPLICA_SUMMARY" "Files imported:" 2 "Both photos reached the replica"

log_success "Test $TEST_NUMBER passed: the import record persists, badges its source, and stays put"
