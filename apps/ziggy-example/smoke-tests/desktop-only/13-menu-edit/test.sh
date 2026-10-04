#!/usr/bin/env bash

# The Edit menu's items edit the text area: select all, cut, paste, copy, undo and redo.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

# Cut takes everything out, and paste puts it back.
insert_text notes "hello world"
wait_for_value notes "hello world"
choose_menu_item select-all
choose_menu_item cut
wait_for_value notes ""
choose_menu_item paste
wait_for_value notes "hello world"

# Copy keeps the text, and a paste adds it again after what replaced the selection.
choose_menu_item select-all
choose_menu_item copy
insert_text notes "X"
wait_for_value notes "X"
choose_menu_item paste
wait_for_value notes "Xhello world"

# Undo takes the paste back, and redo does it again.
choose_menu_item undo
wait_for_value notes "X"
choose_menu_item redo
wait_for_value notes "Xhello world"
