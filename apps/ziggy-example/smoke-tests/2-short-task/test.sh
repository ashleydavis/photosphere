#!/usr/bin/env bash

# A short task sends its output text and a progress message, completes, and its job goes away.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
click start-short
wait_for_text output "hello from a short task"
wait_for_text event-log "task-completed hello-short-1 succeeded"
event_log="$(text_of event-log)"
case "$event_log" in
    *'"progressMessage":"short task working"'*)
        ;;
    *)
        fail "no job-progress message in the event log: $event_log"
        ;;
esac
wait_for_empty jobs
