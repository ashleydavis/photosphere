#!/usr/bin/env bash

# A long task queues children and waits for them. Output and progress arrive from the parent and the children while the page
# stays responsive, the job is listed while it runs and gone when the last task ends.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
type_into child-count 3
click start-long
wait_for_text output "long task step 2"
wait_for_text jobs "Long job"
# The page answers commands while the task runs: this very call proves it.
wait_for_text output "child 0 running"
wait_for_text event-log "task-completed hello-long-1 succeeded" 60
for child in 0 1 2; do
    wait_for_text output "child hello-long-1.c$child succeeded"
    wait_for_text event-log "task-completed hello-long-1.c$child succeeded"
done
wait_for_empty jobs
