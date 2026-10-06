#!/usr/bin/env bash

# The page loads an image and a video from the loopback media server that is part of the example's core, and asks it for a
# range of bytes with a script request, which the web view allows only when the server answers with the page's origin allowed.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click start-media
wait_for_text media-status "image loaded 160x120"
wait_for_text media-status "video loaded 3.0s"
wait_for_text media-status "range fetch 206 10 bytes"
expect_text_absent media-status "failed"

# Cancelling the source stops the server, and nothing else is left running.
click cancel-media
wait_for_text event-log "task-completed media-server-1 cancelled"
