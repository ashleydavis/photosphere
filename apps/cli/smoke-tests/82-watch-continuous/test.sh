#!/bin/bash
DESCRIPTION="psi add --watch picks up a file created after it started, and Ctrl-C stops it"

# The point of watch is that it notices a photo the user has just taken, so a test that only ever
# imports once would never exercise the watcher or the poll at all. This one starts the real command,
# drops a file in while it is running, and waits for the asset to appear in the database.
#
# The signal has to reach the CLI itself. `bun run start --` spawns the CLI as a grandchild and does
# not forward SIGINT, so the command is started under bash job control (macOS has no setsid) and
# leads its own process group, which is signalled the way a terminal signals a foreground job.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# Windows cannot be sent a Ctrl+C from here, for the reasons written out in full in
# smoke-tests/78-dbs-share-cancel/test.sh. It reports SKIP and is counted separately, never as a pass.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    log_info "SKIP: Ctrl+C cannot be delivered to a native console process from Git Bash, so this test cannot run on Windows."
    exit "${TEST_SKIPPED_EXIT_CODE:-77}"
fi

TEST_NUMBER="${1:-82}"
print_test_header "$TEST_NUMBER" "WATCH CONTINUOUS"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
TEST_DB_DIR="$TEST_DIR/test-db"
WATCH_DIR="$TEST_DIR/photos"
WATCH_LOG="$TEST_DIR/watch.log"
mkdir -p "$WATCH_DIR"

CLI_COMMAND=$(get_cli_command)

# Process group of the watch command, signalled when the test is done with it.
WATCH_PGID=""

#
# Kills the watch command if it is still running. Registered so a failure part way through does not
# leave a process behind holding the watched folder.
#
stop_watch_command() {
    if [ -n "$WATCH_PGID" ] && [ "$WATCH_PGID" -gt 1 ]; then
        kill -INT -"$WATCH_PGID" 2>/dev/null || true
        WATCH_PGID=""
    fi
}

#
# Kills the watch command and hands the script's real exit code on to the shared summary.
#
# The exit code has to be captured before anything else runs: cleanup_and_show_summary reads $? and
# decides pass or fail from it, so a cleanup step in front of it overwrites the failure with its own
# success and the test reports PASS however it went. That is not a hypothetical; this test was
# written that way first and reported PASS while failing.
#
on_exit() {
    local exit_code=$?
    stop_watch_command
    return $exit_code
}
trap 'on_exit; cleanup_and_show_summary' EXIT

#
# Starts the watch command in its own process group and waits until it says it is watching.
#
start_watch_command() {
    : > "$WATCH_LOG"

    set -m
    env NODE_ENV=testing $CLI_COMMAND add --db "$TEST_DB_DIR" "$WATCH_DIR" --watch --yes > "$WATCH_LOG" 2>&1 &
    local command_pid=$!
    set +m

    WATCH_PGID="$command_pid"

    local attempt
    for attempt in $(seq 1 120); do
        sleep 0.5
        if grep -q "Watching for new media. Press Ctrl-C to stop." "$WATCH_LOG" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$WATCH_PGID" 2>/dev/null; then
            log_error "The watch command exited before it started watching"
            cat "$WATCH_LOG" 2>/dev/null || true
            return 1
        fi
    done

    log_error "The watch command never reported that it was watching"
    cat "$WATCH_LOG" 2>/dev/null || true
    return 1
}

#
# Waits until the database has recorded the given number of imports. Waits well past the poll
# interval, because the poll is the slowest way a new file can be noticed and is the one that has to
# work where the operating system's watcher does not.
#
# This asks the database what it has imported rather than counting files in the asset directory. The
# original file is written before the batch is committed, so a file count reaches the expected number
# while the import is still in progress: stopping the watch at that moment left the metadata
# uncommitted and the test failed later, and only under load, which is the worst way to find out.
#
wait_for_imported_count() {
    local expected="$1"
    local attempt
    for attempt in $(seq 1 45); do
        local summary
        summary=$(NODE_ENV=testing $CLI_COMMAND summary --db "$TEST_DB_DIR" --yes 2>/dev/null)
        local actual
        actual=$(echo "$summary" | grep "Files imported:" | grep -o '[0-9]\+' | head -1)
        actual="${actual:-0}"
        if [ "$actual" -ge "$expected" ]; then
            log_success "The database has imported $actual file(s)"
            return 0
        fi
        sleep 2
    done

    log_error "The database never reached $expected imported file(s)"
    cat "$WATCH_LOG" 2>/dev/null || true
    return 1
}

#
# Sends SIGINT to the watch command's process group and waits for it to stop.
#
cancel_watch_command() {
    if [ -z "$WATCH_PGID" ] || [ "$WATCH_PGID" -le 1 ]; then
        log_error "Refusing to signal process group '$WATCH_PGID'"
        return 1
    fi

    kill -INT -"$WATCH_PGID"

    local attempt
    for attempt in $(seq 1 60); do
        sleep 0.5
        if ! kill -0 "$WATCH_PGID" 2>/dev/null; then
            WATCH_PGID=""
            return 0
        fi
    done

    log_error "The watch command was still running 30s after Ctrl+C"
    return 1
}

invoke_command "Initialize database" "$CLI_COMMAND init --db $TEST_DB_DIR --yes"

# A file that was there before the watch started, so the backfill has something to do as well.
cp "$TEST_FILES_DIR/test.png" "$WATCH_DIR/before.png"

start_watch_command || exit 1
log_success "The watch command is running"

wait_for_imported_count 1 || exit 1

# --- The file that matters: one created while the command is already running. ---

cp "$TEST_FILES_DIR/test.jpg" "$WATCH_DIR/after.jpg"
log_info "Dropped a new file into the watched folder"

wait_for_imported_count 2 || exit 1

cancel_watch_command || exit 1
log_success "Ctrl+C stopped the watch"

SUMMARY_OUTPUT=""
invoke_command "Summarize the database" "$CLI_COMMAND summary --db $TEST_DB_DIR --yes" 0 SUMMARY_OUTPUT
expect_output_value "$SUMMARY_OUTPUT" "Files imported:" 2 "Both files were imported"

invoke_command "Verify the database" "$CLI_COMMAND verify --db $TEST_DB_DIR --yes"

test_passed
