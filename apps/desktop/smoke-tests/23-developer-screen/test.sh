#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 23 "developer-screen"

TMP_DIR="$TEST_DIR/tmp"

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        kill_app_tree "$(cat "$TMP_DIR/app.pid")"
    fi
}
trap cleanup EXIT

#
# Polls get-value for the given data-id until its value contains the expected substring.
# Usage: wait_for_value <port> <data-id> <expected-substring>
#
wait_for_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local response
        response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
        if echo "$response" | grep -q "$expected"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for data-id '$data_id' to contain '$expected' (last response: $response)"
    exit 1
}

#
# Polls get-value for the given data-id until its value no longer contains the
# expected substring (e.g. an overlay that has been hidden).
# Usage: wait_for_value_gone <port> <data-id> <substring>
#
wait_for_value_gone() {
    local port="$1"
    local data_id="$2"
    local substring="$3"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local response
        response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
        if ! echo "$response" | grep -q "$substring"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for data-id '$data_id' to stop containing '$substring' (last response: $response)"
    exit 1
}

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Open the About page and wait for the hidden version label to render.
send_command "$APP_PORT" navigate '{"page":"/about"}'
wait_for_value "$APP_PORT" "about-version" "Version"

# Tap the version label the required number of times to enable developer mode.
send_command "$APP_PORT" click '{"dataId":"about-version"}'
send_command "$APP_PORT" click '{"dataId":"about-version"}'
send_command "$APP_PORT" click '{"dataId":"about-version"}'
send_command "$APP_PORT" click '{"dataId":"about-version"}'
wait_for_log "$TMP_DIR" "Developer mode enabled"

# The developer screen is now reachable and lists the Stories tool.
send_command "$APP_PORT" navigate '{"page":"/developer"}'
wait_for_value "$APP_PORT" "developer-page" "Developer"
wait_for_value "$APP_PORT" "developer-tool-stories" "Stories"

# Open Stories from the developer screen and confirm it rendered. Stories is a
# top-level route outside Main, so the navigate command (handled inside Main) no
# longer works here; leave via the in-page back link to remount Main.
send_command "$APP_PORT" click '{"dataId":"developer-tool-stories"}'
wait_for_value "$APP_PORT" "stories-page" "story"
send_command "$APP_PORT" click '{"dataId":"stories-back-link"}'

# Wait for the back link to actually land before navigating on. It goes to "/", which Main redirects
# to /gallery once it has remounted, and the app shows the no-database screen there. Navigating while
# that is still in flight races it: navigate only sets the route hash, so the redirect that lands
# afterwards replaces it and the developer page never renders.
wait_for_value "$APP_PORT" "no-database-loaded" "Welcome to Photosphere"

# Return to the developer screen (developer mode is persisted).
send_command "$APP_PORT" navigate '{"page":"/developer"}'
wait_for_value "$APP_PORT" "developer-page" "Developer"

# The FPS toggle shows the FPS overlay; toggling again hides it. The overlay
# rendered by <FPSStats> contains the text "FPS" inside the data-id wrapper.
wait_for_value "$APP_PORT" "developer-tool-fps-toggle" "Show FPS indicator"
send_command "$APP_PORT" click '{"dataId":"developer-tool-fps-toggle"}'
wait_for_value "$APP_PORT" "fps-indicator" "FPS"
send_command "$APP_PORT" click '{"dataId":"developer-tool-fps-toggle"}'
wait_for_value_gone "$APP_PORT" "fps-indicator" "FPS"

# The Dev Tools item is a persisted toggle. Clicking opens the native DevTools
# and logs the state change; clicking again closes it. Assert via the log so the
# test does not depend on inspecting the DevTools window (keeps it non-flaky).
wait_for_value "$APP_PORT" "developer-tool-devtools" "Developer tools"
send_command "$APP_PORT" click '{"dataId":"developer-tool-devtools"}'
wait_for_log "$TMP_DIR" "Developer tools opened"
send_command "$APP_PORT" click '{"dataId":"developer-tool-devtools"}'
wait_for_log "$TMP_DIR" "Developer tools closed"

# Exit developer mode.
send_command "$APP_PORT" click '{"dataId":"developer-exit"}'
wait_for_log "$TMP_DIR" "Developer mode disabled"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 23 passed: developer-screen"
