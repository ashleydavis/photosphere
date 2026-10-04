#!/usr/bin/env bash

# What every scenario uses: start the app, talk to its test control connection, and check what the page shows.
#
# A scenario sources this file. It defines functions only. The platform library chosen by the runner implements:
#
#   ziggy_platform_prepare <run_dir>
#       Builds the app twice into the run directory: the test build, with the test hooks, and the release build, without.
#       Returns non-zero when a build fails.
#
#   ziggy_platform_start <test_dir> <test|release>
#       Starts the app for one scenario, recording what it started through launch_in_process_group. For the test build
#       it starts the app in test mode, and sets ZIGGY_CONTROL_HOST and
#       ZIGGY_CONTROL_PORT to where the test control connection can be reached from the host. Returns non-zero when the
#       app did not come up.
#
#   ziggy_platform_stop <test_dir>
#       Stops the app and everything it started.
#
#   ziggy_platform_devtools_visible <test_dir> <the page's area before they opened>   (desktop platforms)
#       Succeeds when the developer tools are showing. How a script sees them differs: on Linux and macOS they dock inside the
#       window and shrink the page's area, and on Windows they are a window of their own.
#
#   ziggy_platform_data_dir <test_dir>
#       Prints the directory the app uses for its private data in this scenario, when the host can read it, or nothing.

set -u

SCENARIO_NAME="$(basename "$(dirname "${BASH_SOURCE[1]}")")"
source "$ZIGGY_SMOKE_REPO_ROOT/scripts/lib/process-control.sh"
source "$ZIGGY_SMOKE_DIR/lib/$ZIGGY_SMOKE_PLATFORM.sh"


# Seconds the page has to show something before a wait gives up.
WAIT_TIMEOUT_SECONDS=60

fail() {
    echo "FAILED: $*" >&2
    exit 1
}

#
# Stops the app when the scenario ends, however it ends.
#
stop_app_on_exit() {
    ziggy_platform_stop "$ZIGGY_TEST_DIR" || true
}
trap stop_app_on_exit EXIT

#
# Starts the test build of the app and opens the test control connection.
#
start_test_app() {
    ziggy_platform_start "$ZIGGY_TEST_DIR" test || fail "the app did not start"
    exec 3<>"/dev/tcp/$ZIGGY_CONTROL_HOST/$ZIGGY_CONTROL_PORT" || fail "could not connect to the control connection at $ZIGGY_CONTROL_HOST:$ZIGGY_CONTROL_PORT"
    wait_for_ready
}

#
# Sends one command line on the control connection and prints the answer line. Usage: control <json>
#
control() {
    printf '%s\n' "$1" >&3 || fail "could not write to the control connection"
    local answer
    if ! read -r -t 90 -u 3 answer; then
        fail "no answer from the control connection to $1"
    fi
    printf '%s\n' "$answer"
}

#
# Waits until the page answers commands, which means it has loaded and the bridge works.
#
wait_for_ready() {
    local waited=0
    local answer
    while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
        answer="$(control '{"command":"ready"}')"
        if [ "$(printf '%s' "$answer" | jq -r '.ok')" = "true" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the page never answered a ready command"
}

#
# Clicks the element with the data-id. Usage: click <data-id>
#
click() {
    local answer
    answer="$(control "{\"command\":\"click\",\"dataId\":\"$1\"}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "click $1 failed: $answer"
    fi
}

#
# Prints the text of the element with the data-id. Usage: text_of <data-id>
#
text_of() {
    local answer
    answer="$(control "{\"command\":\"get-text\",\"dataId\":\"$1\"}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "get-text $1 failed: $answer"
    fi
    printf '%s' "$answer" | jq -r '.value'
}

#
# Sets the value of the input with the data-id. Usage: type_into <data-id> <text>
#
type_into() {
    local answer
    answer="$(control "{\"command\":\"type\",\"dataId\":\"$1\",\"text\":\"$2\"}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "type into $1 failed: $answer"
    fi
}

#
# Waits until the text of the element contains the text, and fails with what it did show when it never does.
# Usage: wait_for_text <data-id> <text> [seconds]
#
wait_for_text() {
    local data_id="$1"
    local wanted="$2"
    local seconds="${3:-$WAIT_TIMEOUT_SECONDS}"
    local waited=0
    local shown=""
    while [ "$waited" -lt "$seconds" ]; do
        shown="$(text_of "$data_id")"
        case "$shown" in
            *"$wanted"*)
                return 0
                ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    fail "$data_id never showed \"$wanted\". It showed: $shown"
}

#
# Fails when the text of the element contains the text. Usage: expect_text_absent <data-id> <text>
#
expect_text_absent() {
    local shown
    shown="$(text_of "$1")"
    case "$shown" in
        *"$2"*)
            fail "$1 shows \"$2\" and should not. It showed: $shown"
            ;;
    esac
}

#
# Prints how many times the text appears in the element's text. Usage: count_in <data-id> <text>
#
count_in() {
    local shown
    shown="$(text_of "$1")"
    printf '%s' "$shown" | grep -o -F -- "$2" | wc -l | tr -d ' '
}

#
# Waits until the element's text is empty. Usage: wait_for_empty <data-id> [seconds]
#
wait_for_empty() {
    local data_id="$1"
    local seconds="${2:-$WAIT_TIMEOUT_SECONDS}"
    local waited=0
    local shown=""
    while [ "$waited" -lt "$seconds" ]; do
        shown="$(text_of "$data_id")"
        if [ -z "$shown" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$data_id never became empty. It showed: $shown"
}


#
# Says what the next native file or folder dialog returns, so a scenario can use a picker without a dialog being shown. The
# answer answers one dialog. Usage: answer_next_dialog <JSON array of paths>
#
answer_next_dialog() {
    local answer
    answer="$(control "{\"command\":\"pick-answer\",\"paths\":$1}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "the answer for the next dialog was not accepted: $answer"
    fi
}

#
# Chooses a menu item as a user would, through the shell, so the shell's own actions really happen and any other action reaches the
# page. Usage: choose_menu_item <action>
#
choose_menu_item() {
    local answer
    answer="$(control "{\"command\":\"menu\",\"action\":\"$1\"}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "choosing the menu item $1 failed: $answer"
    fi
}

#
# Prints the size in pixels of the area the page is drawn in, as <width>x<height>. Zooming, docking the developer tools and going
# full screen change it.
#
viewport_size() {
    control '{"command":"viewport"}' | jq -r '.value'
}

#
# Waits until the page's area is a size other than the one given, and prints the new size. Fails when it never is.
# Usage: wait_for_viewport_other_than <size>
#
wait_for_viewport_other_than() {
    local waited=0
    local now
    while [ "$waited" -lt 30 ]; do
        now="$(viewport_size)"
        if [ "$now" != "$1" ]; then
            printf '%s\n' "$now"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the page's area stayed $1"
}

#
# Waits until the page's area is the size given. Fails when it never is. Usage: wait_for_viewport <size>
#
wait_for_viewport() {
    local waited=0
    while [ "$waited" -lt 30 ]; do
        if [ "$(viewport_size)" = "$1" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "the page's area never went back to $1. It is $(viewport_size)"
}

#
# Types text into an element the way typing does, so the browser can undo it. Usage: insert_text <data-id> <text>
#
insert_text() {
    local answer
    answer="$(control "{\"command\":\"insert\",\"dataId\":\"$1\",\"text\":\"$2\"}")"
    if [ "$(printf '%s' "$answer" | jq -r '.ok')" != "true" ]; then
        fail "insert into $1 failed: $answer"
    fi
}

#
# Waits until the value of the input or text area is the text given. Fails when it never is. Usage: wait_for_value <data-id> <text>
#
wait_for_value() {
    local waited=0
    local shown=""
    while [ "$waited" -lt 30 ]; do
        shown="$(control "{\"command\":\"get-value\",\"dataId\":\"$1\"}" | jq -r '.value')"
        if [ "$shown" = "$2" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$1 never held \"$2\". It held: $shown"
}
