#!/usr/bin/env bash

# The edges of the bridge: a large payload, text with quotes, newlines and non-ASCII characters, an error reply,
# a failing task, a file in the app's data directory, and the native host callback.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click send-large
wait_for_text edge-result "large payload ok"

click send-unicode
wait_for_text edge-result "unicode ok"

click invoke-fail
wait_for_text edge-result "error reply: ExampleFailure"

click file-roundtrip
wait_for_text edge-result "file ok"
data_dir="$(ziggy_platform_data_dir "$ZIGGY_TEST_DIR")"
if [ -n "$data_dir" ]; then
    written="$(cat "$data_dir/ziggy-example-roundtrip.txt")"
    if [ "$written" != "written by Zig é 世界" ]; then
        fail "the file in the data directory holds: $written"
    fi
fi

click start-fail
wait_for_text event-log "task-completed hello-fail-1 failed HelloFailure"

click os-version
wait_for_text edge-result "operating system: "
shown="$(text_of edge-result)"
if [ "$shown" = "operating system: " ] || [ "$shown" = "operating system: undefined" ] || [ "$shown" = "operating system: null" ]; then
    fail "the native host callback gave no version: $shown"
fi
