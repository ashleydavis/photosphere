#!/usr/bin/env bash

# The file and folder pickers: each button asks the core for a native dialog on the channel the Electron app uses, and the page
# shows what was chosen, or that nothing was. The scenario answers the dialogs itself, so none is shown.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

# Several files from the file dialog are listed one to a line.
answer_next_dialog '["/answers/one.jpg","/answers/two photos/two.jpg"]'
click pick-files
wait_for_text picked "pick-files: 2 paths"
wait_for_text picked "/answers/one.jpg"
wait_for_text picked "/answers/two photos/two.jpg"

# A folder.
answer_next_dialog '["/answers/my folder"]'
click pick-folder
wait_for_text picked "pick-folder: 1 path"
wait_for_text picked "/answers/my folder"

# Where to save a file.
answer_next_dialog '["/answers/saved.txt"]'
click pick-file
wait_for_text picked "pick-file: 1 path"
wait_for_text picked "/answers/saved.txt"

# A cancelled dialog is shown as cancelled, and replaces what was shown before.
answer_next_dialog '[]'
click pick-files
wait_for_text picked "pick-files: cancelled, nothing was chosen"
expect_text_absent picked "/answers/saved.txt"
