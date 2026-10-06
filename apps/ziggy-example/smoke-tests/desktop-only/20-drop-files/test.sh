#!/usr/bin/env bash

# A file dropped on the window reaches the page with its real path from window.ziggy.getPathForFile, and a drop the shell reported no
# files for gives the page no files.
#
# No tool can drag a file into the window of an app running on a virtual display, so the scenario does what a drop does in two
# steps: the drop command records the file with the core, as the shell does when the files are dropped, and the drop-file command
# makes the page receive a drop event carrying a File. The shell's own reading of a real drop is tested by hand.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

# A drop the shell recorded no files for gives the page no files.
answer="$(control '{"command":"drop-file","dataId":"drop-zone","fileName":"two words.txt","fileSize":5}')"
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "the drop-file command failed: $answer"
fi
wait_for_text drop-result "dropped: no files"

mkdir -p "$ZIGGY_TEST_DIR/dropped"
printf 'hello' > "$ZIGGY_TEST_DIR/dropped/two words.txt"
dropped_path="$ZIGGY_TEST_DIR/dropped/two words.txt"
if [ "$ZIGGY_SMOKE_PLATFORM" = "windows" ]; then
    dropped_path="$(windows_native_path "$dropped_path")"
fi

answer="$(control "$(jq -cn --arg path "$dropped_path" '{command: "drop", paths: [$path]}')")"
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "the drop command failed: $answer"
fi
answer="$(control '{"command":"drop-file","dataId":"drop-zone","fileName":"two words.txt","fileSize":5}')"
if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
    fail "the drop-file command failed: $answer"
fi
wait_for_text drop-result "dropped: $dropped_path"
