#!/usr/bin/env bash

# The release build has no test hooks: it contains no control connection, and starting it in test mode changes nothing.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The test build contains the control connection's code and the release build does not.
for file in $(ziggy_platform_artifact_files test); do
    if ! grep -a -q "InvalidCommand" "$file"; then
        fail "the test build $file has no control connection, so this check proves nothing"
    fi
done
for file in $(ziggy_platform_artifact_files release); do
    if grep -a -q "InvalidCommand" "$file"; then
        fail "the release build $file contains the control connection"
    fi
    if grep -a -q "test-command" "$file"; then
        fail "the release build $file contains the test command channel"
    fi
done

# Started in test mode, the release build still opens no control connection.
ziggy_platform_start "$ZIGGY_TEST_DIR" release || fail "the release build did not start"
sleep 8
if ! ziggy_platform_is_running "$ZIGGY_TEST_DIR"; then
    fail "the release build is not running"
fi
if ziggy_platform_has_control_port "$ZIGGY_TEST_DIR"; then
    fail "the release build opened a control connection"
fi
