#!/usr/bin/env bash

# The test control connection answers a line that is not a command with an error, never runs it, and keeps working.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app

printf 'this is not json\n' >&3
read -r -t 20 -u 3 answer || fail "no answer to a line that is not JSON"
case "$answer" in
    *InvalidCommand*)
        ;;
    *)
        fail "a line that is not JSON was not answered with an error: $answer"
        ;;
esac

printf '{"dataId":"start-short"}\n' >&3
read -r -t 20 -u 3 answer || fail "no answer to an object with no command"
case "$answer" in
    *InvalidCommand*)
        ;;
    *)
        fail "an object with no command was not answered with an error: $answer"
        ;;
esac

# Nothing was run, and the connection still works.
sleep 1
expect_text_absent output "hello from a short task"
click start-short
wait_for_text output "hello from a short task"
