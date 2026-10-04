#!/usr/bin/env bash

# The View menu's items do their work in the shell: reload starts the page afresh, and zoom changes the size of the area the page is
# drawn in. The developer tools have a scenario of their own, because how they show up differs between platforms.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

start_test_app

# Reload: the page's state goes and the page starts again.
choose_menu_item start-short
wait_for_text output "hello from a short task"
choose_menu_item reload
wait_for_empty output
wait_for_text reply "says: hello from the page"

normal="$(viewport_size)"

# Zoom in, zoom out, and back to actual size.
choose_menu_item zoom-in
wait_for_viewport_other_than "$normal" > /dev/null
choose_menu_item zoom-reset
wait_for_viewport "$normal"
choose_menu_item zoom-out
wait_for_viewport_other_than "$normal" > /dev/null
choose_menu_item zoom-reset
wait_for_viewport "$normal"

