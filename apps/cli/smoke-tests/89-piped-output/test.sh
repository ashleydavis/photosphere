#!/bin/bash
DESCRIPTION="A command's output survives being piped to a reader that is slow to start"

# `process.exit` does not wait for output that has been written but has not left the process yet.
# When the output is a terminal that never matters, and when it is a pipe it matters a great deal:
# writes queue up, and exiting throws away whatever is still queued. Every `psi` command ends through
# `exit()` in packages/node-utils/src/lib/termination.ts, so every command could lose the end of what
# it printed, silently, with a zero exit code.
#
# It was found through 73-s3-pagination, which failed only when the machine was busy: `find-orphans`
# printed 1,100 orphans and a summary after them, the capture stopped part way through the list, and
# the test read the missing summary as an enumeration of zero objects. Three separate investigations
# went looking at S3 for a fault that was in the exit.
#
# This test reproduces it on an idle machine instead of waiting for a busy one. The reader sleeps
# before reading a single byte, which fills the pipe exactly as a loaded machine does, and the output
# is far larger than any pipe buffer so there is certain to be something left to lose. Nothing here
# touches S3 or media, so it is fast and has nothing to contend on.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

TEST_NUMBER="${1:-89}"

# Per-process scratch directory: a single-test run does not clear the tree the way a full suite run
# does, so a fixed name would collide with the last run's output.
TEST_DIR="$(get_test_dir "$TEST_NUMBER")/run-$$"

# Enough orphans, with long enough names, that the command prints a few hundred kilobytes: comfortably
# more than a pipe holds, so the end of the output is certain to still be inside the process when it
# exits. Creating them is a few hundred milliseconds, because they are empty files.
ORPHAN_COUNT=3000
ORPHAN_NAME_PREFIX="orphaned-object-with-a-long-enough-name-to-fill-a-pipe-"

# How long the reader waits before reading anything. Long enough that the writer has finished and
# exited by the time the first byte is taken out of the pipe.
READER_DELAY_SECONDS=5

trap 'cleanup_and_show_summary' EXIT

test_piped_output() {
    local test_number="$1"
    print_test_header "$test_number" "PIPED OUTPUT SURVIVES THE EXIT"

    local db_path="$TEST_DIR/db"
    local capture_path="$TEST_DIR/find-orphans-capture.txt"
    mkdir -p "$TEST_DIR"

    invoke_command "Initialize the database" "$(get_cli_command) init --db \"$db_path\" --yes" 0

    log_info "Creating $ORPHAN_COUNT orphaned files ..."
    mkdir -p "$db_path/asset"
    local index=0
    while [ "$index" -lt "$ORPHAN_COUNT" ]; do
        : > "$db_path/asset/$ORPHAN_NAME_PREFIX$index.txt"
        index=$((index + 1))
    done

    # The reader that is slow to start. Everything the command prints has to survive it.
    log_info "Running find-orphans into a reader that waits ${READER_DELAY_SECONDS}s before reading ..."
    local stderr_path="$TEST_DIR/find-orphans-stderr.txt"
    eval "$(get_cli_command) find-orphans --db \"$db_path\" --yes" 2> "$stderr_path" \
        | { sleep "$READER_DELAY_SECONDS"; cat; } > "$capture_path"

    # The last thing the command prints. If the exit dropped anything at all, this is what went.
    if ! grep -qF "remove-orphans" "$capture_path"; then
        log_error "The last line the command prints is not in the capture, so its output was cut short."
        log_error "The capture ends:"
        tail -3 "$capture_path" | sed 's/^/    /'
        log_error "It wrote this to stderr:"
        tail -5 "$stderr_path" | sed 's/^/    /'
        exit 1
    fi
    log_success "The command's last line reached the reader"

    # And the whole of the list before it, not just the summary.
    local captured_orphans
    captured_orphans="$(grep -c "$ORPHAN_NAME_PREFIX" "$capture_path")"
    expect_value "$captured_orphans" "$ORPHAN_COUNT" "Every orphan the command printed reached the reader"

    # The summary the harness reads a number out of, which is what 73-s3-pagination lost.
    local reported_orphans
    if ! reported_orphans="$(parse_numeric "$(cat "$capture_path")" "Found")"; then
        log_error "The summary line is missing from the capture."
        exit 1
    fi
    expect_value "$reported_orphans" "$ORPHAN_COUNT" "The summary line survived with the right count"

    test_passed
}

test_piped_output "$TEST_NUMBER"
