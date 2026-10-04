#!/usr/bin/env bash

# Three long tasks run at once under three sources. Cancelling one source cancels that task and leaves the other two running to the end.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
click start-many
wait_for_text event-log "task-message hello-long-1 "
wait_for_text event-log "task-message hello-long-2 "
wait_for_text event-log "task-message hello-long-3 "
click cancel-many-first
wait_for_text event-log "task-completed hello-long-1 cancelled"
wait_for_text event-log "task-completed hello-long-2 succeeded" 60
wait_for_text event-log "task-completed hello-long-3 succeeded" 60
expect_text_absent event-log "task-completed hello-long-2 cancelled"
expect_text_absent event-log "task-completed hello-long-3 cancelled"
wait_for_empty jobs
