#!/bin/bash

# Shared helpers for Photosphere's smoke tests. Source this file from each test.sh:
#   source "$TEST_DIR/../lib/common.sh"
#
# A scenario starts the app in test mode, drives it through the test control connection (see "Test hooks" in the Ziggy architecture
# document) and checks what it logs and what the page shows. The helpers keep the names and arguments the desktop and mobile suites
# of the apps they replace use, so a scenario reads the same whichever app it was written for.
#
# The platform library chosen by the runner (lib/<platform>.sh) implements:
#
#   photosphere_platform_prepare <run_dir>
#       Builds the app with the test hooks into the run directory. Returns non-zero when a build fails.
#
#   photosphere_platform_start <test_dir> [keep-data]
#       Starts the app for one scenario, recording what it started through launch_in_process_group, in test mode, with its settings,
#       vault, logs and data inside the scenario's directory. Its output goes to <test_dir>/app.log. Sets PHOTOSPHERE_CONTROL_HOST and
#       PHOTOSPHERE_CONTROL_PORT to where the test control connection can be reached from the host. Returns non-zero when the app did not
#       come up. With keep-data it starts the app again on the data the last run left, on a phone on the same install.
#
#   photosphere_platform_stop <test_dir>
#       Stops the app and everything it started.
#
#   photosphere_platform_wait_exit <test_dir> <seconds>
#       Waits for the app to end. Returns non-zero when it is still running after the time.
#
#   photosphere_platform_is_running <test_dir>
#       Succeeds when the app's process is running.
#
#   photosphere_platform_screenshot <output_path>        (optional)
#       Writes a PNG of the app's screen to the host path. Defined only by a platform whose app cannot write to a host path, which is a
#       phone: send_command then takes the screenshot command from the host instead of sending it to the app. A platform that does not
#       define it has the app write the PNG itself.
#
#   photosphere_platform_reset_app_state
#       Clears everything the app has stored, for a deterministic start. A desktop does nothing, because the scenario's directory is
#       fresh. A phone wipes the app's storage and keychain. Call it before the start. Returns non-zero when the wipe failed or was refused.

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directory containing this script, and the repository it sits in.
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTOSPHERE_SMOKE_DIR="${PHOTOSPHERE_SMOKE_DIR:-$(cd "$COMMON_LIB_DIR/.." && pwd)}"
PHOTOSPHERE_SMOKE_REPO_ROOT="${PHOTOSPHERE_SMOKE_REPO_ROOT:-$(cd "$COMMON_LIB_DIR/../../.." && pwd)}"
REPO_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT"
SMOKE_REPO_ROOT="$PHOTOSPHERE_SMOKE_REPO_ROOT"

# Per-test temporary directories, and starting and stopping background processes: shared with the other suites so there is one
# implementation rather than a copy per caller.
source "$REPO_DIR/scripts/lib/test-lib.sh"
source "$REPO_DIR/scripts/lib/process-control.sh"
source "$REPO_DIR/scripts/lib/test-timeout.sh"

# The platform the scenario runs on: linux, windows, macos, android or ios. The runner sets it. A scenario run by hand on a desktop
# gets the host's.
if [ -z "${PHOTOSPHERE_SMOKE_PLATFORM:-}" ]; then
    case "$(uname -s)" in
        Linux*)
            PHOTOSPHERE_SMOKE_PLATFORM="linux"
            ;;
        Darwin*)
            PHOTOSPHERE_SMOKE_PLATFORM="macos"
            ;;
        *)
            PHOTOSPHERE_SMOKE_PLATFORM="windows"
            ;;
    esac
fi
PLATFORM="$PHOTOSPHERE_SMOKE_PLATFORM"
export PHOTOSPHERE_SMOKE_DIR PHOTOSPHERE_SMOKE_PLATFORM PHOTOSPHERE_SMOKE_REPO_ROOT

# The build of the app a scenario run by hand uses is the one in the run directory, which the runner makes. A scenario run by hand
# names it.
PHOTOSPHERE_SMOKE_RUN_DIR="${PHOTOSPHERE_SMOKE_RUN_DIR:-}"
export PHOTOSPHERE_SMOKE_RUN_DIR

source "$PHOTOSPHERE_SMOKE_DIR/lib/$PHOTOSPHERE_SMOKE_PLATFORM.sh"

# Default seconds a wait tolerates before failing, doubled from the standalone value so a concurrent suite run sharing the machine
# (which slows everything) does not trip a spurious timeout.
DEFAULT_WAIT_TIMEOUT=120

# Seconds between looks in every wait below. A quarter second costs about an eighth of a second per wait and four looks a second per
# test, which the whole pool running at once can bear.
WAIT_POLL_INTERVAL=0.25

# Clean up the app even when a run is interrupted (Ctrl-C) or the runner's timeout kills a slow test (SIGTERM), not only on a normal
# exit. A bash EXIT trap does not fire on an uncaught signal, so turn those signals into an exit here: that runs the per-test EXIT trap
# (stop_app), leaving nothing orphaned.
trap 'exit 130' INT
trap 'exit 143' TERM

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

print_test_header() {
    local test_number="$1"
    local test_name="$2"
    echo ""
    echo "============================================================================"
    echo "=== TEST $test_number: $test_name ==="
    echo "============================================================================"
}

#
# Returns the current directory as a native OS path. On Windows (Git Bash), pwd returns POSIX paths (/d/a/...) which native Windows
# processes cannot resolve correctly. pwd -W returns the Windows form (D:/a/...) that both bash and native processes understand.
#
native_pwd() {
    if [ "$PLATFORM" = "windows" ]; then
        pwd -W
    else
        pwd
    fi
}

# TMP_DIR is where a test keeps its app log, pid file, config, vault and anything else it writes. The runner allocates it and hands it
# down in PHOTOSPHERE_TMP_DIR; a test run on its own, straight from the command line, allocates its own here so it is isolated either
# way. Converted to a native path because the app is a native process.
if [ -n "${PHOTOSPHERE_TMP_DIR:-}" ]; then
    TMP_DIR="$PHOTOSPHERE_TMP_DIR"
else
    TMP_DIR="$(photosphere_test_temp_dir "$(basename "$(dirname "$0")")")"
    photosphere_export_test_temp "$TMP_DIR"
fi
mkdir -p "$TMP_DIR"
TMP_DIR="$(cd "$TMP_DIR" && native_pwd)"

# On a desktop every app and CLI a scenario starts shares this machine with every other scenario and every other run, so the
# scenario gets a LAN share discovery port of its own rather than the default 54321. On the default port a sender pairs with any
# receiver that announces the same pairing code, and the codes the app draws for itself are not claimed against anyone else's, so
# two shares that drew one code would deliver to each other. Exported before anything starts, since the apps and the CLI all read
# it. A device has its own network stack, so it keeps the default.
if [ "$PLATFORM" != "android" ] && [ "$PLATFORM" != "ios" ]; then
    PHOTOSPHERE_LAN_SHARE_PORT="$(allocate_lan_share_port)" || exit 1
    export PHOTOSPHERE_LAN_SHARE_PORT
    log_info "LAN share discovery port: $PHOTOSPHERE_LAN_SHARE_PORT"
fi

# The fixtures a scenario hands the app (a database to open, photos to drop) are paths in the repository, so the repository's path is
# converted to the native form too. Git Bash converts a path that is a whole argument of a native program by itself, but not one inside
# a JSON message, which is how most of them reach the app.
REPO_DIR="$(cd "$REPO_DIR" && native_pwd)"

#
# Sends one command line on the test control connection and prints the answer line. Every call opens a connection of its own, so
# several instances can be driven from one scenario by naming the port of each. A signal that reaches this script while bash connects,
# such as the exit of a child it started, makes connect fail with "Interrupted system call", which bash reports and does not retry, so
# that failure is tried again. Prints nothing and returns non-zero when no answer came.
# Usage: control_command <port> <json>
#
control_command() {
    local port="$1"
    local command_json="$2"
    local host="${PHOTOSPHERE_CONTROL_HOST:-127.0.0.1}"
    local error_file="$TMP_DIR/control-connect-error.txt"
    local attempt=1
    while ! { exec 3<>"/dev/tcp/$host/$port"; } 2>"$error_file"; do
        if ! grep -q "Interrupted system call" "$error_file" || [ "$attempt" -ge 5 ]; then
            cat "$error_file" >&2
            return 1
        fi
        attempt=$((attempt + 1))
    done
    printf '%s\n' "$command_json" >&3
    local answer=""
    if ! read -r -t 90 -u 3 answer; then
        exec 3>&-
        return 1
    fi
    exec 3>&-
    printf '%s\n' "$answer"
}

#
# Clears everything the app has stored (on a phone its storage, the web view's data and the keychain), so a scenario starts from a known
# state. Call it before start_app. A failure to clear fails the scenario rather than letting it run on state an earlier one left.
# Usage: reset_app_state
#
reset_app_state() {
    if ! photosphere_platform_reset_app_state; then
        log_error "The app's stored data could not be cleared"
        exit 1
    fi
}

#
# Launches the app in test mode as a background process, and publishes the port of its test control connection as the APP_PORT global
# that callers use. For a second concurrent instance, copy APP_PORT into your own variable right after the call (see the share tests).
# Usage: start_app <tmp_dir> [x_position]
#
# On Linux the app runs headlessly on a virtual display. Set SHOW_UI=1 to show the window instead (useful for debugging a failing test).
#
start_app() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir"
    if ! photosphere_platform_start "$tmp_dir"; then
        log_error "The app did not start"
        exit 1
    fi
    APP_PORT="$PHOTOSPHERE_CONTROL_PORT"
    APP_TMP_DIR="$tmp_dir"
    log_info "App started (PID $(cat "$tmp_dir/app.pid" 2>/dev/null || echo unknown), control port $APP_PORT)"
}

#
# Stops whatever each of the given tmp directories has running, and is the only thing a test's cleanup needs to call. Tolerates a
# directory that was never used, so it is safe in an unconditional trap and safe to call twice.
# Usage: cleanup_apps <tmp_dir> [tmp_dir ...]
#
cleanup_apps() {
    local tmp_dir
    for tmp_dir in "$@"; do
        if [ -z "$tmp_dir" ] || [ ! -d "$tmp_dir" ]; then
            continue
        fi
        photosphere_platform_stop "$tmp_dir" || true
    done
    return 0
}

#
# Waits until the page answers commands, which means it has loaded and the bridge works. The relaunch the Electron suite did when its
# control server bound but the page never came up has no counterpart here: a page that does not answer fails the scenario.
# Usage: wait_for_ready <port>
#
wait_for_ready() {
    local port="${1:-$APP_PORT}"
    log_info "Waiting for app to be ready on port $port..."
    local deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
    local answer
    while [ "$SECONDS" -lt "$deadline" ]; do
        answer="$(control_command "$port" '{"command":"ready"}' || true)"
        if [ "$(printf '%s' "$answer" | jq -r '.ok // empty' 2>/dev/null)" = "true" ]; then
            log_info "App is ready"
            return 0
        fi
        # A desktop app that has already ended will never answer, so waiting out the whole timeout only hides that it ended. The
        # log says how it ended (a shell prints "Killed" there when something sent it SIGKILL).
        case "$PLATFORM" in
            linux|macos|windows)
                if ! photosphere_platform_is_running "$APP_TMP_DIR"; then
                    log_error "The app exited before it was ready. Its log:"
                    tail -30 "$TMP_DIR/app.log" 2>/dev/null
                    exit 1
                fi
                ;;
        esac
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "The app was not ready after ${DEFAULT_WAIT_TIMEOUT}s. Its log:"
    tail -30 "$TMP_DIR/app.log" 2>/dev/null
    dump_app_stacks "$APP_TMP_DIR"
    exit 1
}

#
# Prints the stack of every thread of the app, and of every process it started, so a start-up that hangs says where. It runs
# before the cleanup kills the app, and only on the path where the app is still running but never became ready. A missing
# stack tool is said so on the output, never skipped quietly. Usage: dump_app_stacks <test_dir>
#
dump_app_stacks() {
    local test_dir="$1"
    local root_pid stack_pid thread_dir
    root_pid="$(cat "$test_dir/app.pid" 2>/dev/null)"
    if [ -z "$root_pid" ]; then
        log_error "No stacks: $test_dir/app.pid is missing, so the app's pid is not known."
        return 0
    fi
    case "$PLATFORM" in
        linux)
            # The thread listing below needs no gdb, so a missing gdb skips only the stacks. It once returned here instead, and
            # 38-reset-device-s3 hanging in the Release Zig Linux workflow (run 40161921825, where gdb is not installed) left
            # nothing at all to say where the app was waiting.
            for stack_pid in $(process_tree_pids "$root_pid"); do
                if ! command -v gdb > /dev/null 2>&1; then
                    log_error "No stacks of pid $stack_pid: gdb is not installed, so the stacks of the hung app cannot be read."
                else
                    log_error "Stacks of pid $stack_pid ($(ps -o comm= -p "$stack_pid" 2>/dev/null)):"
                    if ! gdb -p "$stack_pid" -batch -ex "thread apply all bt" 2>&1 | tee -a "$test_dir/hang-stacks.txt"; then
                        log_error "gdb failed on pid $stack_pid."
                    fi
                fi
                # With the kernel's default ptrace_scope of 1 a process may attach only to its descendants, and the app was
                # reparented away from the test when its launcher exited, so gdb is often refused. Each thread's name, state
                # and the kernel function it waits in are readable without ptrace and show which threads are stuck.
                log_error "Threads of pid $stack_pid (tid, name, state, waiting in):"
                for thread_dir in /proc/"$stack_pid"/task/*; do
                    echo "$(basename "$thread_dir") $(cat "$thread_dir/comm" 2>/dev/null) $(awk '{ print $3 }' "$thread_dir/stat" 2>/dev/null) $(cat "$thread_dir/wchan" 2>/dev/null)" | tee -a "$test_dir/hang-stacks.txt"
                done
            done
            ;;
        macos)
            if ! command -v lldb > /dev/null 2>&1; then
                log_error "No stacks: lldb is not installed, so the stacks of the hung app cannot be read."
                return 0
            fi
            for stack_pid in $(process_tree_pids "$root_pid"); do
                log_error "Stacks of pid $stack_pid ($(ps -o comm= -p "$stack_pid" 2>/dev/null)):"
                lldb -p "$stack_pid" -b -o "thread backtrace all" 2>&1 | tee -a "$test_dir/hang-stacks.txt"
            done
            ;;
        *)
            log_error "No stacks: there is no stack tool for $PLATFORM."
            ;;
    esac
    return 0
}

#
# Polls app.log until pattern matches or the timeout is reached. Tracks a per-log cursor (in $tmp_dir/.log-cursor) so each call only
# sees lines logged after the previous successful match. This avoids races where a repeated pattern (for example "Databases page
# loaded" on a re-navigation) matches a stale occurrence and returns before the new event has actually fired.
# Usage: wait_for_log <tmp_dir> <pattern> [timeout]
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-$DEFAULT_WAIT_TIMEOUT}"
    local cursor_file="$tmp_dir/.log-cursor"
    local start_line=0
    if [ -f "$cursor_file" ]; then
        start_line=$(cat "$cursor_file")
    fi
    log_info "Waiting for log pattern: $pattern (after line $start_line)"
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$tmp_dir/app.log" ]; then
            local matched_line
            matched_line=$(awk -v start="$start_line" -v pat="$pattern" '
                NR > start && index($0, pat) > 0 { print NR; exit }
            ' "$tmp_dir/app.log" 2>/dev/null)
            if [ -n "$matched_line" ]; then
                echo "$matched_line" > "$cursor_file"
                log_info "Found: $pattern (line $matched_line)"
                return 0
            fi
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for log pattern: $pattern"
    log_error "Last 30 lines of app.log:"
    tail -30 "$tmp_dir/app.log" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
    # The import scenarios of the macOS arm64 release workflow timed out here with the core's log ending just after the import made
    # its file scanning directory, no crash report and nothing else to say where the import had stopped. The app's stacks say that.
    dump_app_stacks "$tmp_dir"
    # Exit the test with non-zero so the runner reports FAIL. Without this the test would keep running on stale state and eventually
    # reach log_success, producing a false pass.
    exit 1
}

#
# Resets wait_for_log's cursor back to the start of app.log. The app's output goes to app.log with `>`, which truncates it, so a test
# that stops the app and starts it again gets a log that begins at line 1 while the cursor still points at wherever the previous run
# finished. Call this straight after restarting the app.
# Usage: reset_log_cursor <tmp_dir>
#
reset_log_cursor() {
    local tmp_dir="$1"
    echo "0" > "$tmp_dir/.log-cursor"
}

#
# Polls app.log for the pattern anywhere in the whole log, not only after wait_for_log's cursor, and leaves the cursor where it was. For
# a line that can arrive either side of the line a previous wait stopped at. Fails the test on timeout.
# Usage: wait_for_log_anywhere <tmp_dir> <pattern> [timeout]
#
wait_for_log_anywhere() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-$DEFAULT_WAIT_TIMEOUT}"
    log_info "Waiting for log pattern anywhere in the log: $pattern"
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$tmp_dir/app.log" ] && grep -qF -- "$pattern" "$tmp_dir/app.log"; then
            log_info "Found: $pattern"
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for log pattern: $pattern"
    log_error "Last 30 lines of app.log:"
    tail -30 "$tmp_dir/app.log" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
    exit 1
}

#
# Waits until every asset load that started has finished: the number of "Starting load" lines is compared with the number of "Load
# assets task completed" lines, which gives the same answer whatever order they arrived in.
# Usage: wait_for_asset_loads_to_settle <tmp-dir> [timeout]
#
wait_for_asset_loads_to_settle() {
    local tmp_dir="$1"
    local timeout="${2:-$DEFAULT_WAIT_TIMEOUT}"
    local deadline=$((SECONDS + timeout))
    local started=0
    local finished=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        started=$(grep -c "\[loadAssets\] Starting load" "$tmp_dir/app.log" 2>/dev/null || true)
        finished=$(grep -c "Load assets task completed" "$tmp_dir/app.log" 2>/dev/null || true)
        if [ "${started:-0}" -gt 0 ] && [ "${finished:-0}" -ge "${started:-0}" ]; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Asset loads did not settle within ${timeout}s: ${started:-0} started, ${finished:-0} finished."
    return 1
}

#
# Reads the current value of the element with the given data-id, echoing it to stdout (empty when the element is absent or the page
# says it cannot be read). Value-returning helper: it prints and never exits, so it is safe inside $(...) and safe to call after a
# failed assertion to report what the screen actually said.
# Usage: read_value <port> <data-id>
#
read_value() {
    local port="$1"
    local data_id="$2"
    local answer
    answer="$(control_command "$port" "$(jq -cn --arg dataId "$data_id" '{command: "get-value", dataId: $dataId}')" || true)"
    printf '%s' "$answer" | jq -r '.value // empty' 2>/dev/null
}

#
# Polls the element's value until it contains the expected substring. Fails the test on timeout. Use this to wait for a control to
# reach a known state before acting on it: each command the driver receives is handled independently, so a command sent into a UI that
# has not caught up yet can be overtaken by the one after it.
# Usage: wait_for_value <port> <data-id> <expected-substring> [timeout]
#
wait_for_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
    local response=""
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        response="$(read_value "$port" "$data_id")"
        if printf '%s' "$response" | grep -q -F -- "$expected"; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for data-id '$data_id' to contain '$expected' (last value: $response)"
    exit 1
}

#
# Polls the element's value until it matches the extended regular expression. For a value where a substring would also match a wrong
# one, such as "1 photos" inside "11 photos". Fails the test on timeout.
# Usage: wait_for_value_matching <port> <data-id> <ere> [timeout]
#
wait_for_value_matching() {
    local port="$1"
    local data_id="$2"
    local pattern="$3"
    local timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
    local response=""
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        response="$(read_value "$port" "$data_id")"
        if printf '%s' "$response" | grep -q -E -- "$pattern"; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for data-id '$data_id' to match '$pattern' (last value: $response)"
    exit 1
}

#
# The opposite wait: polls the given data-id until its value no longer contains the substring, for watching a control leave a state
# (a button that says Cancel while a job runs, a dialog that shows a pairing code until it is dismissed). A non-empty value is required
# first. Without that a dead app, which answers nothing at all, reads exactly like a dialog that has closed, and the test passes on the
# strength of the app having crashed.
# Usage: wait_for_value_gone <port> <data-id> <substring> [timeout]
#
wait_for_value_gone() {
    local port="$1"
    local data_id="$2"
    local unwanted="$3"
    local timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
    local response=""
    local answer
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        # The answer itself is what must be non-empty, as in the Electron suite whose reply was always a JSON body: an element that
        # has gone reads as an empty value in an answer that says ok, whereas a dead app gives no answer.
        answer="$(control_command "$port" "$(jq -cn --arg dataId "$data_id" '{command: "get-value", dataId: $dataId}')" || true)"
        response="$(printf '%s' "$answer" | jq -r '.value // empty' 2>/dev/null)"
        if [ "$(printf '%s' "$answer" | jq -r '.ok // empty' 2>/dev/null)" = "true" ] && ! printf '%s' "$response" | grep -q -F -- "$unwanted"; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for data-id '$data_id' to stop containing '$unwanted' (last value: $response)"
    return 1
}

#
# Polls the share dialog's pairing code until it reads as four digits, prints it on stdout and returns non-zero when none appeared
# inside the timeout. The four digit test is what distinguishes a code from the placeholder the dialog shows while it is still being
# generated.
# Usage: read_pairing_code <port> [timeout]
#
read_pairing_code() {
    local port="$1"
    local timeout="${2:-$DEFAULT_WAIT_TIMEOUT}"
    local code=""
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        code=$(read_value "$port" share-pairing-code)
        if [[ "$code" =~ ^[0-9]{4}$ ]]; then
            echo "$code"
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    return 1
}

#
# Waits until the share dialog stops showing a pairing code, which is how a cancelled share is seen to have stopped: cancelling closes
# the dialog and takes the code out of the page. Any four digit code means the share is still up, not one particular one, so this is a
# pattern test rather than the substring test wait_for_value_gone does. The app has to have answered before its value is believed: an
# app that has died answers nothing, and reads exactly like a dialog that closed, so a run where no request is answered ends in the
# failure and never in a pass. Returns non-zero when a code is still showing, or nothing answered, when the timeout ends.
# Usage: wait_for_pairing_code_gone <port> [timeout]
#
wait_for_pairing_code_gone() {
    local port="$1"
    local timeout="${2:-$DEFAULT_WAIT_TIMEOUT}"
    local answer
    local showing=""
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        answer="$(control_command "$port" '{"command":"get-value","dataId":"share-pairing-code"}' || true)"
        if [ "$(printf '%s' "$answer" | jq -r '.ok // empty' 2>/dev/null)" = "true" ]; then
            showing="$(printf '%s' "$answer" | jq -r '.value // empty' 2>/dev/null)"
            if ! [[ "$showing" =~ ^[0-9]{4}$ ]]; then
                return 0
            fi
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    return 1
}

#
# Sends a command to the page (or to the core, for the ones it answers itself) and fails when it did not do what was asked. The body
# is the JSON object of the command's arguments, and the endpoint is the command's name.
# Usage: send_command <port> <command> [json_body]
#
send_command() {
    local port="$1"
    local endpoint="$2"
    local body="${3:-}"
    if [ -z "$body" ]; then
        body="{}"
    fi
    local command_json
    command_json="$(printf '%s' "$body" | jq -c --arg command "$endpoint" '. + {command: $command}')" || {
        log_error "The body of the $endpoint command is not JSON: $body"
        return 1
    }
    # A platform whose app cannot write a file where the host can read it (a phone's path is on the phone) takes the screenshot from the
    # host and writes the PNG to the path the command names.
    if [ "$endpoint" = "screenshot" ] && declare -F photosphere_platform_screenshot > /dev/null; then
        local output_path
        output_path="$(printf '%s' "$command_json" | jq -r '.outputPath // empty')"
        if [ -z "$output_path" ]; then
            log_error "The screenshot command needs an outputPath: $body"
            return 1
        fi
        photosphere_platform_screenshot "$output_path"
        return $?
    fi
    local response
    if ! response="$(control_command "$port" "$command_json")"; then
        log_error "No answer from the control connection on port $port to $endpoint"
        return 1
    fi
    if [ "$(printf '%s' "$response" | jq -r '.ok // empty' 2>/dev/null)" != "true" ]; then
        log_error "Command failed: $response"
        return 1
    fi
    return 0
}

#
# Sends the quit command, then stops the app if it does not end within a few seconds. The wait watches the app's process group empty
# rather than sleeping a fixed period at it; a wedged app is stopped exactly as before, since cleanup_apps runs either way.
# Usage: stop_app <port> <tmp_dir>
#
stop_app() {
    local port="$1"
    local tmp_dir="$2"
    send_command "$port" quit '{}' 2>/dev/null || true
    photosphere_platform_wait_exit "$tmp_dir" 5 || true
    cleanup_apps "$tmp_dir"
}

#
# Starts the local MinIO S3 emulator in the given state directory and reads back what it bound.
#
# On return S3_EMULATOR_PORT, S3_EMULATOR_BUCKET, S3_EMULATOR_ACCESS_KEY and S3_EMULATOR_SECRET_KEY are exported (from the emulator's
# own env file), along with S3_ENDPOINT, the http:// URL the app reaches it at. The endpoint is addressed by IP, never "localhost":
# without path-style addressing the SDK puts the bucket into the hostname, which on a machine that resolves *.localhost reaches the
# server but names no bucket, so a listing comes back empty rather than failing.
#
# A failure to start is fatal: an S3 test that cannot get a server must fail, never skip.
# Usage: start_s3_emulator <state-dir>
#
start_s3_emulator() {
    local state_dir="$1"

    mkdir -p "$state_dir"
    if ! (cd "$SMOKE_REPO_ROOT" && bun run s3-emulator start "$state_dir"); then
        log_error "Could not start the local S3 emulator"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$state_dir/env"
    local host_address="127.0.0.1"
    case "$PLATFORM" in
        android|ios)
            # The server runs on the host, so a phone reaches it at the address the host has for the phone, never at loopback, which on
            # a device means the device itself. A real Android device reaches the host only through an adb reverse, so the port is
            # exposed first; that is a no-op on an emulator and on the iOS simulator.
            "${PLATFORM}_expose_host_port" "$S3_EMULATOR_PORT" || exit 1
            host_address="$("${PLATFORM}_host_address")" || exit 1
            ;;
    esac
    export S3_ENDPOINT="http://$host_address:$S3_EMULATOR_PORT"
    log_info "S3 emulator at $S3_ENDPOINT, bucket $S3_EMULATOR_BUCKET"
}

#
# Stops the S3 emulator recorded in the given state directory. Never fails, including when nothing was ever started, so it is safe in
# an unconditional trap.
# Usage: stop_s3_emulator <state-dir>
#
stop_s3_emulator() {
    local state_dir="$1"
    (cd "$SMOKE_REPO_ROOT" && bun run s3-emulator stop "$state_dir") >/dev/null 2>&1 || true
    return 0
}

#
# Adds an s3-credentials secret through the app's own Add Secret dialog, the way a user would, rather than writing the vault file
# directly. Every field is filled: a secret carrying only a region cannot reach a server, so the tests that actually connect need all
# five. The secrets page must already be showing, and the type defaults to s3-credentials so no type switch is needed. Expects TMP_DIR
# to be set, as wait_for_log takes it.
# Usage: add_s3_secret_via_ui <port> <name> <endpoint> <region> <access-key> <secret-key>
#
add_s3_secret_via_ui() {
    local port="$1"
    local name="$2"
    local endpoint="$3"
    local region="$4"
    local access_key="$5"
    local secret_key="$6"

    send_command "$port" click '{"dataId":"add-secret-button"}'
    wait_for_log "$TMP_DIR" "Add secret dialog opened"
    send_command "$port" type "{\"dataId\":\"secret-name-input\",\"text\":\"$name\"}"
    send_command "$port" type "{\"dataId\":\"secret-s3-endpoint-input\",\"text\":\"$endpoint\"}"
    send_command "$port" type "{\"dataId\":\"secret-s3-region-input\",\"text\":\"$region\"}"
    send_command "$port" type "{\"dataId\":\"secret-s3-access-key-input\",\"text\":\"$access_key\"}"
    send_command "$port" type "{\"dataId\":\"secret-s3-secret-key-input\",\"text\":\"$secret_key\"}"
    send_command "$port" click '{"dataId":"add-secret-confirm"}'
    wait_for_log "$TMP_DIR" "Secret added"
}

#
# Greps app.log for [ERROR] lines and fails if any are found. An optional second argument is an extended-regex of [ERROR] lines to
# ignore, for an error a test provokes on purpose (the S3 test deliberately browses with bad credentials and asserts the failure is
# surfaced); any remaining [ERROR] line still fails the check.
# Usage: check_no_errors <tmp_dir> [ignore_regex]
#
check_no_errors() {
    local tmp_dir="$1"
    local ignore_pattern="${2:-}"
    local errors
    if [ -n "$ignore_pattern" ]; then
        errors=$(grep '\[ERROR\]' "$tmp_dir/app.log" 2>/dev/null | grep -Ev "$ignore_pattern")
    else
        errors=$(grep '\[ERROR\]' "$tmp_dir/app.log" 2>/dev/null)
    fi
    if [ -n "$errors" ]; then
        log_error "Errors found in app.log:"
        echo "$errors" | while IFS= read -r line; do
            echo "  $line"
        done
        # Fatal by construction: signalling failure by return let a test print [FAIL], fall through to log_success and exit 0 (a false
        # pass). It is never called from a cleanup path or a command substitution, so exit is safe.
        exit 1
    fi
    log_success "No errors in app.log"
    return 0
}

#
# Merges one secret into the plaintext vault's single vault.json file, which holds every secret keyed by its name. The merge is a
# read-modify-write, so seeding a second secret keeps the first. An absent vault file starts from an empty object. A vault file that
# does not parse fails the test outright rather than being silently replaced with a fresh one.
# Usage: merge_vault_secret <vault-dir> <secret-json>
#
merge_vault_secret() {
    local vault_dir="$1"
    local secret_json="$2"
    local vault_file="$vault_dir/vault.json"

    mkdir -p "$vault_dir"
    if [ ! -f "$vault_file" ]; then
        printf '%s' '{}' > "$vault_file"
    fi

    local merged
    if ! merged=$(jq -c --argjson secret "$secret_json" '. + {($secret.name): $secret}' "$vault_file"); then
        echo "Vault file $vault_file is not valid JSON" >&2
        exit 1
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

#
# Returns success when a vault directory's vault.json holds a secret under the given name.
# Usage: vault_has_secret <vault-dir> <name>
#
vault_has_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local vault_file="$vault_dir/vault.json"

    if [ ! -f "$vault_file" ]; then
        return 1
    fi
    jq -e --arg name "$secret_name" 'has($name)' "$vault_file" > /dev/null 2>&1
}

#
# Seeds one secret into the plaintext vault, in the JSON envelope the vault stores a secret in (an object with name, type and value,
# where value is always a string). For an s3-credentials secret that string is itself JSON, so pass the already-encoded JSON document
# as the value.
# Usage: write_vault_secret <vault-dir> <name> <type> <value>
#
write_vault_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local secret_value="$4"
    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --arg value "$secret_value" \
        '{name: $name, type: $type, value: $value}')"
}

#
# The same, with the secret's value read verbatim from a file, newlines and all, which is how a multi-line PEM gets in.
# Usage: write_vault_secret_from_file <vault-dir> <name> <type> <value-file>
#
write_vault_secret_from_file() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local value_file="$4"
    merge_vault_secret "$vault_dir" "$(jq -cn --arg name "$secret_name" --arg type "$secret_type" --rawfile value "$value_file" \
        '{name: $name, type: $type, value: $value}')"
}

#
# Creates a database at the given path through the CLI, importing any image files passed after the path. Every CLI call is checked and
# its output printed on failure, so a failed import is reported where it happens and not as an empty gallery later. A phone seeds the
# result onto the device with ${PLATFORM}_seed_database.
# Usage: create_database <db_path> [image ...]
#
create_database() {
    local db_path="$1"
    shift

    local cli_output
    if ! cli_output="$( cd "$REPO_DIR/apps/cli" && bun run start -- init --db "$db_path" --yes 2>&1 )"; then
        log_error "Creating the database at $db_path failed. The CLI said:"
        echo "$cli_output" | sed 's/^/  /'
        exit 1
    fi

    local image
    for image in "$@"; do
        if ! cli_output="$( cd "$REPO_DIR/apps/cli" && bun run start -- add "$image" --db "$db_path" --yes 2>&1 )"; then
            log_error "Adding $image to the database at $db_path failed. The CLI said:"
            echo "$cli_output" | sed 's/^/  /'
            exit 1
        fi
    done
}

#
# Adds a secret through the real Add Secret dialog, so a test that needs a pre-existing secret on a phone (where the vault cannot be
# written from the host) creates it the way a user would. The Secrets page must already be showing.
# The value is the one field the tests read back: the S3 region for s3-credentials, or the key for api-key. An encryption-key is
# created with an empty PEM, because the driver types into <input> elements and not into the PEM <textarea>.
# Usage: add_secret_via_ui <port> <name> <type: s3-credentials|encryption-key|api-key> <value>
#
add_secret_via_ui() {
    local port="$1"
    local name="$2"
    local secret_type="$3"
    local value="$4"

    send_command "$port" click '{"dataId":"add-secret-button"}' || return 1
    wait_for_log "$TMP_DIR" "Add secret dialog opened"
    send_command "$port" type "{\"dataId\":\"secret-name-input\",\"text\":\"$name\"}" || return 1

    # The type defaults to s3-credentials; only switch it when a different type is asked for.
    if [ "$secret_type" != "s3-credentials" ]; then
        send_command "$port" click '{"dataId":"secret-type-select"}' || return 1
        send_command "$port" click "{\"dataId\":\"secret-type-option-$secret_type\"}" || return 1
    fi

    case "$secret_type" in
        s3-credentials)
            send_command "$port" type "{\"dataId\":\"secret-s3-region-input\",\"text\":\"$value\"}" || return 1
            ;;
        api-key)
            send_command "$port" type "{\"dataId\":\"secret-value-input\",\"text\":\"$value\"}" || return 1
            ;;
        encryption-key)
            ;;
    esac

    send_command "$port" click '{"dataId":"add-secret-confirm"}' || return 1
    wait_for_log "$TMP_DIR" "Secret added"
}

# The exit code a scenario ends with when it skips, which the runner reports as skipped and not as passed.
TEST_SKIPPED_EXIT_CODE=77

# How many times, and how many seconds apart, require_lan_bridge looks for the emulator on the host LAN bridge.
LAN_BRIDGE_PROBE_ATTEMPTS=5
LAN_BRIDGE_PROBE_INTERVAL_SECONDS=1

#
# Runs a command under a wall-clock cap, so a wedged process cannot hang the whole suite. Uses `timeout`, or `gtimeout` where coreutils
# installs it under that name (MacOS). Stdout passes straight through, so callers can capture it. A machine with neither (a stock MacOS)
# falls back to run_test_with_timeout's shell cap, which kills the process tree and also returns 124 when the cap is reached.
# Usage: run_with_timeout <seconds> <command...>
#
run_with_timeout() {
    local seconds="$1"
    shift
    # type -P and the resolved path, not `command -v` and a bare name: command -v finds shell functions, and function lookup beats PATH.
    local timeout_bin
    timeout_bin="$(type -P timeout 2>/dev/null)"
    if [ -z "$timeout_bin" ]; then
        timeout_bin="$(type -P gtimeout 2>/dev/null)"
    fi
    if [ -z "$timeout_bin" ]; then
        run_test_with_timeout "$seconds" "$@"
        return $?
    fi
    "$timeout_bin" --kill-after=5 "$seconds" "$@"
}

#
# Runs the psi CLI from source against a vault and config isolated under the test's own tmp dir, so a test never reads or writes the
# developer's real OS keychain or database list. Both variables are required for isolation: PHOTOSPHERE_VAULT_DIR alone still selects
# the keychain vault unless PHOTOSPHERE_VAULT_TYPE says otherwise. stdin is closed so an unexpected interactive prompt aborts instead of
# hanging the run, and NO_COLOR keeps the output greppable.
# Usage: run_cli <tmp_dir> <cli args...>
#
run_cli() {
    local tmp_dir="$1"
    shift
    (
        cd "$REPO_DIR/apps/cli" && \
        NO_COLOR=1 \
        PHOTOSPHERE_VAULT_TYPE="plaintext" \
        PHOTOSPHERE_VAULT_DIR="$tmp_dir/cli-vault" \
        PHOTOSPHERE_CONFIG_DIR="$tmp_dir/cli-config" \
        run_with_timeout 90 bun run start -- "$@" </dev/null
    )
}

#
# Runs the psi CLI built from the Zig source (by run.sh, at PHOTOSPHERE_ZIG_CLI), isolated the same way as run_cli.
# Usage: run_zig_cli <tmp_dir> <cli args...>
#
run_zig_cli() {
    local tmp_dir="$1"
    shift
    NO_COLOR=1 \
    PHOTOSPHERE_VAULT_TYPE="plaintext" \
    PHOTOSPHERE_VAULT_DIR="$tmp_dir/cli-vault" \
    PHOTOSPHERE_CONFIG_DIR="$tmp_dir/cli-config" \
    run_with_timeout 90 "$PHOTOSPHERE_ZIG_CLI" "$@" </dev/null
}

#
# Fails the test unless the Android emulator is attached to the host LAN bridge. Host-to-device LAN sharing needs it: under QEMU's
# default user-mode NAT the guest's discovery broadcast never reaches the host, so a host-side sender would silently wait out its full
# 60-second timeout and exit 0. Detected from the guest's wlan0 address. Does nothing off Android, and on a real device, which shares
# the host's LAN already. A run that sets PHOTOSPHERE_NO_LAN_BRIDGE=1 declares it cannot have a bridge and skips instead of failing.
# Usage: require_lan_bridge
#
require_lan_bridge() {
    if [ "$PLATFORM" != "android" ]; then
        return 0
    fi
    case "${ANDROID_SERIAL:-}" in
        ""|emulator-*)
            ;;
        *)
            log_success "Running on real device ${ANDROID_SERIAL}, which shares the host's LAN, so the emulator bridge is not needed."
            return 0
            ;;
    esac
    # The probe has to ask the device this run uses, so it claims one first: with more than one emulator attached a bare adb refuses.
    photosphere_android_claim_device || exit 1
    # Being on the bridge is a static property of the emulator, so one unlucky sample must not decide it.
    local attempt=0
    local probe_output=""
    while [ "$attempt" -lt "$LAN_BRIDGE_PROBE_ATTEMPTS" ]; do
        probe_output=$(photosphere_adb shell ip addr show wlan0 2>&1 | tr -d '\r')
        if echo "$probe_output" | grep -q 'inet 192\.168\.55\.'; then
            log_success "Emulator is on the host LAN bridge."
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$LAN_BRIDGE_PROBE_INTERVAL_SECONDS"
    done
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        log_info "SKIP: this test needs the host LAN bridge and PHOTOSPHERE_NO_LAN_BRIDGE=1 says this run has none. Skipping."
        exit "$TEST_SKIPPED_EXIT_CODE"
    fi
    log_error "The emulator is not on the host LAN bridge, so a host-to-device LAN transfer cannot work."
    log_error "Probed wlan0 $LAN_BRIDGE_PROBE_ATTEMPTS times; adb last reported: ${probe_output:-<no output>}"
    log_error "Bring it up with: bun run emu:and:up"
    exit 1
}

#
# Runs a psi CLI LAN send and fails the test unless it reports a successful transfer. The exit code alone is NOT a usable signal: when
# the sender never discovers a receiver it prints "No device found within 60 seconds." and still exits 0. Output is written to
# <tmp_dir>/sender.log and named on failure.
# Usage: cli_send_expect_success <tmp_dir> <cli args...>
#
cli_send_expect_success() {
    local tmp_dir="$1"
    shift
    local sender_log="$tmp_dir/sender.log"
    run_cli "$tmp_dir" "$@" >"$sender_log" 2>&1 || true
    if ! grep -q "sent successfully" "$sender_log"; then
        log_error "The CLI sender did not report a successful transfer. Sender output: $sender_log"
        exit 1
    fi
    log_success "CLI sender reported a successful transfer."
}

#
# Asserts immediately (no polling) that the element's value matches <expected_regex>, exiting 1 otherwise. An empty value never matches.
# Usage: assert_value <port> <dataId> <expected_regex>
#
assert_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local value
    value=$(read_value "$port" "$data_id")
    if [ -z "$value" ] || ! echo "$value" | grep -qE "$expected"; then
        log_error "Value of '$data_id' ('$value') did not match: $expected"
        exit 1
    fi
    log_info "Value of '$data_id' matched: $value"
    return 0
}

#
# Prints the path of a file in the app's settings directory, as the app sees it: the directory the scenario's config files are written
# to on a desktop, and the app's settings directory on a phone. Usage: config_file_path <name>
#
config_file_path() {
    case "$PLATFORM" in
        android|ios)
            "${PLATFORM}_config_file_path" "$1"
            ;;
        *)
            echo "$TMP_DIR/config/$1"
            ;;
    esac
}

#
# Puts a file from the host into the app's settings directory from outside the app, replacing one of the same name, the way a scenario
# pre-writes databases.toml. Usage: put_config_file <host_file> <name>
#
put_config_file() {
    case "$PLATFORM" in
        android|ios)
            "${PLATFORM}_put_config_file" "$1" "$2"
            ;;
        *)
            mkdir -p "$TMP_DIR/config" && cp "$1" "$TMP_DIR/config/$2"
            ;;
    esac
}

#
# Prints a file of the app's settings directory as it stands, or nothing when there is none, which is how a scenario asserts on a write
# the app made. Usage: read_config_file <name>
#
read_config_file() {
    case "$PLATFORM" in
        android|ios)
            "${PLATFORM}_read_config_file" "$1"
            ;;
        *)
            if [ -f "$TMP_DIR/config/$1" ]; then
                cat "$TMP_DIR/config/$1"
            fi
            ;;
    esac
}

#
# Opens the page's actions menu, which holds the page's secondary actions on a phone. A desktop page shows those actions directly, so
# there is no menu to open. Usage: open_page_actions_menu <port>
#
open_page_actions_menu() {
    local port="$1"
    case "$PLATFORM" in
        android|ios)
            send_command "$port" click '{"dataId":"page-actions-menu"}' || return 1
            ;;
    esac
}

#
# Opens the left sidebar and clicks one of its items, the way a user opens the New database, Open database and Configuration
# dialogs on every platform. A phone has no menu bar, so the sidebar is the one path that is the same everywhere.
# Usage: click_sidebar_item <port> <new-database|open-database|configuration>
#
click_sidebar_item() {
    local port="$1"
    local item="$2"
    send_command "$port" click '{"dataId":"sidebar-toggle-button"}' || return 1
    send_command "$port" click "{\"dataId\":\"sidebar-$item\"}" || return 1
}

#
# Clicks one of a database row's actions on the Databases page. A phone folds a row's actions into the row's menu, which is opened
# first, and the open menu holds the one set of action buttons. A desktop shows every row's buttons, so the row is the button's index.
# Usage: click_database_row_action <port> <row_index> <action_data_id>
#
click_database_row_action() {
    local port="$1"
    local row_index="$2"
    local action_data_id="$3"
    case "$PLATFORM" in
        android|ios)
            send_command "$port" click "{\"dataId\":\"entity-actions-menu\",\"nth\":$row_index}" || return 1
            send_command "$port" click "{\"dataId\":\"$action_data_id\",\"nth\":0}" || return 1
            ;;
        *)
            send_command "$port" click "{\"dataId\":\"$action_data_id\",\"nth\":$row_index}" || return 1
            ;;
    esac
}

#
# Imports host files into the open database through the import page, which must be showing. A desktop drops the files on the page's
# drop zone. A phone has no drop zone and its picker is native, so the files are put into the app's import directory from outside the
# app and the picker is answered with their paths, then the picker button is clicked. The files keep their names.
# Usage: import_files <port> <host_file>...
#
import_files() {
    local port="$1"
    shift
    case "$PLATFORM" in
        android|ios)
            local stage_dir="$TMP_DIR/import-stage"
            rm -rf "$stage_dir" || return 1
            mkdir -p "$stage_dir" || return 1
            cp "$@" "$stage_dir/" || return 1
            "${PLATFORM}_seed_database" "$stage_dir" ".import-tmp" || return 1
            local import_tmp_path
            import_tmp_path="$("${PLATFORM}_app_path" ".import-tmp")"
            local paths_json
            paths_json="$(for host_file in "$@"; do basename "$host_file"; done | jq -R --arg dir "$import_tmp_path" '$dir + "/" + .' | jq -sc '.')"
            send_command "$port" pick-answer "$(jq -cn --argjson paths "$paths_json" '{paths: $paths}')" || return 1
            send_command "$port" click '{"dataId":"import-files-button"}' || return 1
            ;;
        *)
            local paths_json
            paths_json="$(printf '%s\n' "$@" | jq -R '.' | jq -sc '.')"
            send_command "$port" drop "$(jq -cn --argjson paths "$paths_json" '{dataId: "import-drop-zone", paths: $paths}')" || return 1
            ;;
    esac
}

#
# Copies a database in the app's files directory to a directory on the host, replacing what is there, so the host's CLI can read what
# the app wrote. The app must not be writing to it. Usage: fetch_app_database <relative_path_under_files> <host_dest>
#
fetch_app_database() {
    local rel_path="$1"
    local host_dest="$2"
    rm -rf "$host_dest" || return 1
    mkdir -p "$(dirname "$host_dest")" || return 1
    case "$PLATFORM" in
        android|ios)
            "${PLATFORM}_fetch_database" "$rel_path" "$host_dest" || return 1
            ;;
        *)
            cp -r "$("${PLATFORM}_app_path" "$rel_path")" "$host_dest" || return 1
            ;;
    esac
}

#
# Succeeds when a file of the app's settings directory exists, even when it is empty. Usage: config_file_exists <name>
#
config_file_exists() {
    case "$PLATFORM" in
        android|ios)
            "${PLATFORM}_config_file_exists" "$1"
            ;;
        *)
            [ -f "$TMP_DIR/config/$1" ]
            ;;
    esac
}

#
# Succeeds when the vault holds a secret of the given name, as the app's own list of secrets has it. A desktop keeps its vault in a
# file the scenario can read. A phone keeps secrets in the device keychain, which nothing outside the app can read, so the Secrets
# page, which lists what the vault holds, is read instead. Returns 0 when the vault holds it, 1 when the vault is readable and does not,
# and 2 when the app could not be asked (so a dead app is never taken for an absent secret). Usage: secret_in_vault <port> <name>
#
secret_in_vault() {
    local port="$1"
    local secret_name="$2"
    case "$PLATFORM" in
        android|ios)
            send_command "$port" navigate '{"page":"secrets"}' || return 2
            wait_for_log "$TMP_DIR" "Secrets page loaded" || return 2
            local answer
            answer="$(control_command "$port" "$(jq -cn --arg dataId "secret-row-name-$secret_name" '{command: "get-value", dataId: $dataId}')")" || return 2
            if [ "$(printf '%s' "$answer" | jq -r '.ok // empty' 2>/dev/null)" != "true" ]; then
                return 2
            fi
            [ -n "$(printf '%s' "$answer" | jq -r '.value // empty' 2>/dev/null)" ]
            ;;
        *)
            vault_has_secret "$TMP_DIR/vault" "$secret_name"
            ;;
    esac
}

#
# Damages the vault the way a truncated write or a damaged disk would, from outside the app, so reading it fails. A desktop app reads
# its vault file each time, so it is damaged under the running app. A phone app opens its keychain once, when it starts, so the app is
# stopped, the keychain damaged and the app started again on the same data, which is a new log. Fails when there is no vault to
# damage. Usage: damage_vault
#
damage_vault() {
    case "$PLATFORM" in
        android|ios)
            stop_app "$APP_PORT" "$TMP_DIR"
            "${PLATFORM}_damage_vault" || return 1
            start_app "$TMP_DIR"
            reset_log_cursor "$TMP_DIR"
            wait_for_ready "$APP_PORT"
            ;;
        *)
            if [ ! -f "$TMP_DIR/vault/vault.json" ]; then
                echo "No vault file at $TMP_DIR/vault/vault.json to damage; the secret was never stored" >&2
                return 1
            fi
            printf '%s' 'this is not json' > "$TMP_DIR/vault/vault.json" || return 1
            ;;
    esac
}

#
# Prints an extended regex of the [ERROR] lines an app logs while it runs on a damaged vault, besides the failed reset itself, for
# check_no_errors. A phone app that was started on a damaged keychain fails to load the secrets its pages show; a desktop app that
# had its vault damaged while running logs nothing more. Usage: damaged_vault_errors_pattern
#
damaged_vault_errors_pattern() {
    case "$PLATFORM" in
        android|ios)
            echo "Device reset failed:|vault|Failed to load app data:"
            ;;
        *)
            echo "Device reset failed:|vault"
            ;;
    esac
}

#
# Prints the path of the database automatic import writes to, as the app recorded it in its settings, or nothing when none is recorded.
# The settings file holds one such path, so it can name only one database. Usage: read_default_database_path
#
# The app's YAML dump wraps a string longer than its line width into a folded block scalar (`>-`), breaking it at a space, so a path
# with a space in it (an iOS container's "Application Support") arrives over several lines. Reading the value back means joining the
# folded lines with a single space, as a YAML loader does. A plain value and a single-quoted one are read too; any other form fails
# loudly rather than returning part of a path.
#
read_default_database_path() {
    local quote="'"
    local line
    local stripped
    local indent
    local key_indent=""
    local value=""
    local folding="false"
    while IFS= read -r line; do
        if [ "$folding" = "true" ]; then
            stripped="${line#"${line%%[! ]*}"}"
            indent=$(( ${#line} - ${#stripped} ))
            if [ -z "$stripped" ]; then
                echo "read_default_database_path: a blank line inside the folded default_database_path is not supported" >&2
                return 1
            fi
            if [ "$indent" -le "$key_indent" ]; then
                break
            fi
            if [ -z "$value" ]; then
                value="$stripped"
            else
                value="$value $stripped"
            fi
            continue
        fi
        if [[ "$line" =~ ^(\ *)default_database_path:\ *(.*)$ ]]; then
            key_indent="${#BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$value" in
                ">-"|">")
                    folding="true"
                    value=""
                    ;;
                "$quote"*"$quote")
                    value="${value:1:${#value}-2}"
                    value="${value//$quote$quote/$quote}"
                    break
                    ;;
                ""|"|"*|"\""*|"$quote"*)
                    echo "read_default_database_path: unsupported form of default_database_path: '$value'" >&2
                    return 1
                    ;;
                *)
                    break
                    ;;
            esac
        fi
    done < <(read_config_file config.yaml)
    printf '%s' "$value"
}

#
# Asserts that the row on the Databases page is the database marked as the default, and that no other row is. The app's recorded
# default is read on every platform. A desktop's table also shows a badge on the default row, so that is read too; a phone's cards show
# no badge, so there is nothing more to read there. Usage: expect_default_database <port> <row_index> <row_count> <database_path>
#
expect_default_database() {
    local port="$1"
    local row_index="$2"
    local row_count="$3"
    local database_path="$4"
    local recorded
    recorded="$(read_default_database_path)" || exit 1
    if [ "$recorded" != "$database_path" ]; then
        log_error "The recorded default database is '$recorded', expected '$database_path'"
        exit 1
    fi
    case "$PLATFORM" in
        android|ios)
            ;;
        *)
            wait_for_value "$port" "database-default-badge-$row_index" "Default"
            # Two badges at once would mean the app believes photos are being backed up to two places while only one of them is really
            # receiving them.
            local other_index=0
            while [ "$other_index" -lt "$row_count" ]; do
                if [ "$other_index" -ne "$row_index" ] && read_value "$port" "database-default-badge-$other_index" | grep -q "Default"; then
                    log_error "Row $other_index is marked as the default as well as row $row_index"
                    exit 1
                fi
                other_index=$((other_index + 1))
            done
            ;;
    esac
}
