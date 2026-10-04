#!/usr/bin/env bash

# Quitting the app with tasks still running ends the app and every process it started.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_test_app
type_into child-count 2
click start-long
click start-many
wait_for_text output "long task step 2"
answer="$(control '{"command":"quit"}')"
case "$answer" in
    *'"ok":true'*)
        ;;
    *)
        fail "the quit command was not accepted: $answer"
        ;;
esac
if ! ziggy_platform_wait_exit "$ZIGGY_TEST_DIR" 30; then
    fail "the app and its processes were still running 30 seconds after the quit command"
fi
