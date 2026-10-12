#!/usr/bin/env bash

# The app's own code in the core reaches the page: an error it describes, a task that reads its own context and the app's state, a task
# that runs children one after another, tasks queued and cancelled from the app's code, the counts the app keeps by observing tasks, and an
# event the app sends that the page stops hearing once it removes its listeners.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

click app-refuse
wait_for_text app-result "error reply: The example refused, as it was asked to."

click app-describe
wait_for_text app-result 'describe-self: {"taskId":"describe-self-1","taskType":"describe-self","source":"describe-source","maxConcurrentChildTasks":'

click app-run-in-turn
wait_for_text app-result 'run-in-turn: {"ran":3,"statuses":["succeeded","succeeded","succeeded"]}'

click app-queue
wait_for_text app-result "queued by the app: from-app-app-source"
wait_for_text event-log "app-event queued from-app-app-source"
wait_for_text event-log "task-completed from-app-app-source succeeded"

click app-start-long
wait_for_text output "long task step 2"
click app-cancel
wait_for_text event-log "task-completed hello-long-3 failed Cancelled"

click app-stats
wait_for_text app-result "tasks ended "
stats="$(text_of app-result)"
case "$stats" in
    *"tasks ended 0,"*|*"messages sent 0"*)
        fail "the app counted nothing of the tasks that ran: $stats"
        ;;
esac

click app-stop-listening
wait_for_text app-result "stopped listening for app events"
click app-queue
wait_for_text event-log "task-completed from-app-app-source succeeded"
completed=0
waited=0
while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
    completed="$(count_in event-log "task-completed from-app-app-source succeeded")"
    if [ "$completed" -ge 2 ]; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
if [ "$completed" -lt 2 ]; then
    fail "the second task the app queued never completed"
fi
heard="$(count_in event-log "app-event queued from-app-app-source")"
if [ "$heard" != "1" ]; then
    fail "the page heard $heard app events, and should have heard only the one before it stopped listening"
fi
