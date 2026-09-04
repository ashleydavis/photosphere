#!/bin/bash
DESCRIPTION="The import record remembers what a database took in, badges manual and automatic apart, stays on this machine and never appears inside a database"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-87}"
print_test_header "$TEST_NUMBER" "IMPORT RECORD"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
LOCAL_DB="$TEST_DIR/local-db"
OTHER_DB="$TEST_DIR/other-db"
REMOTE_DB="$TEST_DIR/remote-db"
REPLICA_DB="$TEST_DIR/replica-db"
WATCH_DIR="$TEST_DIR/photos"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

# The record's path carries a hash of the database path, so this script does not build it: a copy of
# that derivation here would go stale silently the moment the real one changed, and the test would
# then be checking a file nothing writes. It searches the machine's cache directory instead, which
# this suite points at a directory of its own per run, so nothing else is in there to be found.
#
# Prints the record whose contents name the given photo, so two databases' records can be told apart
# without knowing which directory belongs to which.
find_record_naming() {
    local wanted_photo="$1"

    while IFS= read -r candidate; do
        if grep -q "\"logicalPath\":\"[^\"]*$wanted_photo\"" "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(find "$PHOTOSPHERE_CACHE_DIR" -name "imports.dat" 2>/dev/null)

    return 1
}

invoke_command "Initialize the local database" "$CLI_COMMAND init --db $LOCAL_DB --yes"

# --- 1. A manual import is recorded, and badged as manual. ---

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/asked-for.png"
invoke_command "Import a photo by hand" "$CLI_COMMAND add --db $LOCAL_DB $WATCH_DIR/asked-for.png --yes"

RECORD_FILE="$(find_record_naming "asked-for.png")"
if [ -z "$RECORD_FILE" ]; then
    log_error "No import record naming the imported photo was written under $PHOTOSPHERE_CACHE_DIR"
    find "$PHOTOSPHERE_CACHE_DIR" -type f 2>/dev/null
    exit 1
fi
log_success "The import was recorded at $RECORD_FILE"

# The record belongs to this machine, not to the database, so it must be outside the database
# directory. Everything in part 3 rests on this.
case "$RECORD_FILE" in
    "$LOCAL_DB"*)
        log_error "The import record is inside the database at $RECORD_FILE. It belongs on this machine, not in the database several machines share."
        exit 1
        ;;
esac
log_success "The import record lives outside the database"

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

# --- 3. The record is never inside a database, so nothing that copies a database can carry it. ---

# These used to check that consolidate, sync and replicate each left ".db/imports.dat" behind, which
# was guarding an exclusion that had to be arranged: the record was in the database, and only its
# absence from the merkle tree kept it out of those three. It is not in the database any more, so
# what is worth checking is that it never gets back in. A later change that puts it there fails here.
assert_no_record_inside() {
    local database_dir="$1"
    local what_happened="$2"

    if [ ! -d "$database_dir" ]; then
        return 0
    fi

    local found
    found=$(find "$database_dir" -name "imports.dat" -print -quit 2>/dev/null)
    if [ -n "$found" ]; then
        log_error "$what_happened left an import record inside the database at $found. The record belongs to the machine that wrote it: inside a database, several machines overwrite each other's and it travels to databases it never described."
        exit 1
    fi
}

assert_no_record_inside "$LOCAL_DB" "Importing"
log_success "Importing put no record inside the database it imported into"

invoke_command "Create the remote and consolidate into it" "$CLI_COMMAND consolidate --db $LOCAL_DB $REMOTE_DB --yes"
assert_no_record_inside "$LOCAL_DB" "Consolidation"
assert_no_record_inside "$REMOTE_DB" "Consolidation"
log_success "Consolidation put no record inside either database"

invoke_command "Sync to the remote" "$CLI_COMMAND sync --db $LOCAL_DB --yes"
assert_no_record_inside "$LOCAL_DB" "Sync"
assert_no_record_inside "$REMOTE_DB" "Sync"
log_success "Sync put no record inside either database"

invoke_command "Replicate to a third database" "$CLI_COMMAND replicate --db $LOCAL_DB --dest $REPLICA_DB --yes"
assert_no_record_inside "$LOCAL_DB" "Replication"
assert_no_record_inside "$REPLICA_DB" "Replication"
log_success "Replication put no record inside either database"

# The local record survived all three untouched, so the checks above are about where the record is,
# not about it having been lost.
if ! grep -q '"logicalPath":"[^"]*asked-for.png"' "$RECORD_FILE"; then
    log_error "Consolidate, sync or replicate lost this machine's import record"
    exit 1
fi
log_success "This machine's record survived consolidate, sync and replicate"

# --- 4. The photos themselves did travel, so the checks above prove exclusion, not a failed copy. ---

REPLICA_SUMMARY=""
invoke_command "Summarise the replica" "$CLI_COMMAND summary --db $REPLICA_DB --yes" 0 REPLICA_SUMMARY
expect_output_value "$REPLICA_SUMMARY" "Files imported:" 2 "Both photos reached the replica"

# --- 5. Two databases on one machine each get their own record. ---

# This is what the per-database record buys. A single record for the machine would show photos put
# into one database as having gone into the other, which is a lie about where they are.
invoke_command "Initialize a second database" "$CLI_COMMAND init --db $OTHER_DB --yes"

cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/into-the-other.png"
invoke_command "Import a photo into the second database" "$CLI_COMMAND add --db $OTHER_DB $WATCH_DIR/into-the-other.png --yes"

OTHER_RECORD_FILE="$(find_record_naming "into-the-other.png")"
if [ -z "$OTHER_RECORD_FILE" ]; then
    log_error "No record names the photo imported into the second database"
    exit 1
fi

if [ "$OTHER_RECORD_FILE" = "$RECORD_FILE" ]; then
    log_error "A photo imported into the second database was written into the first database's record at $RECORD_FILE. One record for both databases would show photos put into one as having gone into the other."
    exit 1
fi
log_success "The second database has an import record of its own at $OTHER_RECORD_FILE"
if grep -q '"logicalPath":"[^"]*into-the-other.png"' "$RECORD_FILE"; then
    log_error "A photo imported into the second database showed up in the first database's record"
    exit 1
fi
if grep -q '"logicalPath":"[^"]*asked-for.png"' "$OTHER_RECORD_FILE"; then
    log_error "A photo imported into the first database showed up in the second database's record"
    exit 1
fi
log_success "Each database's record holds only what went into that database"

log_success "Test $TEST_NUMBER passed: the import record persists, badges its source, stays on this machine, and is kept per database"
