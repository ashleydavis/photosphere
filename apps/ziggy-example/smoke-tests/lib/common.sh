#!/usr/bin/env bash

# What every scenario uses: start the app, talk to its test control connection, and check what the page shows.
#
# A scenario sources this file. It defines functions only. The platform library chosen by the runner implements:
#
#   ziggy_platform_prepare <run_dir>
#       Builds the app twice into the run directory: the test build, with the test hooks, and the release build, without.
#       Returns non-zero when a build fails.
#
#   ziggy_platform_start <test_dir> <test|release> [keep-data]
#       Starts the app for one scenario, recording what it started through launch_in_process_group. For the test build
#       it starts the app in test mode, and sets ZIGGY_CONTROL_HOST and
#       ZIGGY_CONTROL_PORT to where the test control connection can be reached from the host. Returns non-zero when the
#       app did not come up. With keep-data it starts the app again on the data the last run left, instead of fresh data,
#       and on a phone on the same device and the same install.
#
#   ziggy_platform_stop <test_dir> [keep-device]
#       Stops the app and everything it started. With keep-device a phone stays claimed, so a restart finds its data.
#
#   ziggy_platform_devtools_visible <test_dir> <the page's area before they opened>   (desktop platforms)
#       Succeeds when the developer tools are showing. How a script sees them differs: on Linux and macOS they dock inside the
#       window and shrink the page's area, and on Windows they are a window of their own.
#
#   ziggy_platform_leave_app <test_dir>
#       Takes the app out of the user's sight without ending it: on a desktop it closes the window (the File menu's Close Window), on
#       Android it presses Home, and on the iOS simulator it opens another app over it. Returns non-zero when it cannot, which is
#       the case on a connected iPhone or iPad.
#
#   ziggy_platform_process_alive <test_dir>
#       Succeeds when the app's process is running, whether or not its window or activity is in sight.
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
    open_control_connection
    wait_for_ready
}

#
# Stops the app and starts it again on the data it kept, then opens the control connection to the new run. A scenario uses it to
# check what survives a restart.
#
restart_test_app() {
    exec 3>&-
    ziggy_platform_stop "$ZIGGY_TEST_DIR" keep-device
    ziggy_platform_start "$ZIGGY_TEST_DIR" test keep-data || fail "the app did not start again"
    open_control_connection
    wait_for_ready
}

#
# Opens the test control connection on file descriptor 3. A signal that reaches this script while bash connects, such as the
# exit of a child it started, makes connect fail with "Interrupted system call", which bash reports and does not retry, so that
# failure is tried again. Any other failure ends the scenario.
#
open_control_connection() {
    local error_file="$ZIGGY_TEST_DIR/control-connect-error.txt"
    local attempt=1
    while ! { exec 3<>"/dev/tcp/$ZIGGY_CONTROL_HOST/$ZIGGY_CONTROL_PORT"; } 2>"$error_file"; do
        if ! grep -q "Interrupted system call" "$error_file" || [ "$attempt" -ge 5 ]; then
            cat "$error_file" >&2
            fail "could not connect to the control connection at $ZIGGY_CONTROL_HOST:$ZIGGY_CONTROL_PORT"
        fi
        attempt=$((attempt + 1))
    done
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

#
# Prints the number in a file the app keeps in its data directory (a count a background task writes), or 0 when there is no such
# file yet. Usage: data_file_number <file name>
#
data_file_number() {
    local data_dir
    data_dir="$(ziggy_platform_data_dir "$ZIGGY_TEST_DIR")" || fail "could not read the app's data directory"
    if [ -f "$data_dir/$1" ]; then
        tr -d '\n' < "$data_dir/$1"
    else
        echo 0
    fi
}

#
# Waits until the number in a data file is at least the given value, and prints it. Usage: wait_for_data_file_number <file> <value>
#
wait_for_data_file_number() {
    local waited=0
    local number
    while [ "$waited" -lt "$WAIT_TIMEOUT_SECONDS" ]; do
        number="$(data_file_number "$1")"
        if [ "$number" -ge "$2" ]; then
            printf '%s\n' "$number"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "$1 never reached $2. It holds $number"
}
