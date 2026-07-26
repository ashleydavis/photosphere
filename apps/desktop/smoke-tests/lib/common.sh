#!/bin/bash

# Shared helpers for Electron smoke tests.
# Source this file from each test.sh:
#   source "$TEST_DIR/../lib/common.sh"
# Expects DESKTOP_DIR to be set to the apps/desktop directory.

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default seconds a wait tolerates before failing, doubled from the standalone value so a concurrent
# suite run sharing the machine (which slows everything) does not trip a spurious timeout.
DEFAULT_WAIT_TIMEOUT=120

# Clean up the app even when a run is interrupted (Ctrl-C) or the runner's timeout kills a slow test
# (SIGTERM), not only on a normal exit. A bash EXIT trap does not fire on an uncaught signal, so turn
# those signals into an exit here: that runs the per-test EXIT trap (stop_app), leaving nothing
# orphaned. (A hard SIGKILL still cannot be caught, but that is not the normal path.)
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
    echo "============================================================================"
    echo "=== TEST $test_number: $test_name ==="
    echo "============================================================================"
    echo "============================================================================"
}

#
# Returns the current directory as a native OS path.
# On Windows (Git Bash), pwd returns POSIX paths (/d/a/...) which native
# Windows processes like Electron cannot resolve correctly. pwd -W returns
# the Windows form (D:/a/...) that both bash and native processes understand.
#
native_pwd() {
    if [ "$(detect_platform)" = "win" ]; then
        pwd -W
    else
        pwd
    fi
}

#
# Detects the current OS: linux, mac, or win.
#
detect_platform() {
    case "$(uname -s)" in
        Linux*)             echo "linux";;
        Darwin*)            echo "mac";;
        CYGWIN*|MINGW*|MSYS*) echo "win";;
        *)                  echo "linux";;
    esac
}

#
# Detects the current CPU architecture: x64 or arm64.
#
detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x64";;
        arm64|aarch64) echo "arm64";;
        *)            echo "x64";;
    esac
}

#
# Returns the path to the packaged release binary for the current platform/arch.
#
get_release_binary() {
    local platform arch
    platform=$(detect_platform)
    arch=$(detect_architecture)
    case "$platform" in
        linux)
            echo "$DESKTOP_DIR/release/linux-unpacked/photosphere"
            ;;
        mac)
            if [ "$arch" = "arm64" ]; then
                echo "$DESKTOP_DIR/release/mac-arm64/Photosphere.app/Contents/MacOS/photosphere"
            else
                echo "$DESKTOP_DIR/release/mac/Photosphere.app/Contents/MacOS/photosphere"
            fi
            ;;
        win)
            echo "$DESKTOP_DIR/release/win-unpacked/photosphere.exe"
            ;;
    esac
}

#
# Waits for the app to publish the OS-assigned port its test control server bound and prints it.
# The app binds port 0 and writes the actual port to $tmp_dir/test-control.port. Diagnostics go to
# stderr so callers can capture the port from stdout.
# Usage: wait_for_test_port <port_file>
#
wait_for_test_port() {
    local port_file="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
        if [ -s "$port_file" ]; then
            cat "$port_file"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Test control server did not report a listening port within ${DEFAULT_WAIT_TIMEOUT}s" >&2
    return 1
}

#
# Launches the Electron app in test mode as a background process. The app's test control server
# binds an OS-assigned free port (never a pre-picked number, which could collide with a parallel
# run) and writes it to $tmp_dir/test-control.port; this reads it back and publishes it as the
# APP_PORT global that callers use. For a second concurrent instance, copy APP_PORT into your own
# variable right after the call (see the share tests).
# Usage: start_app <tmp_dir> [x_position]
#
# On Linux the app runs headlessly via xvfb-run by default. Set SHOW_UI=1 to
# show the window instead (useful for debugging a failing test). xvfb-run is
# Linux-only; on macOS/Windows the UI is always shown.
#
start_app() {
    local tmp_dir="$1"
    local x_pos="${2:-0}"
    mkdir -p "$tmp_dir"
    # Clear any stale port file from a previous launch so wait_for_test_port reads this launch's port.
    rm -f "$tmp_dir/test-control.port"
    local launch_args=()
    if [ "${USE_BINARY:-false}" = "true" ]; then
        launch_args+=("$(get_release_binary)")
    else
        local electron_bin
        electron_bin=$(cd "$DESKTOP_DIR" && node -e "process.stdout.write(require('electron'))")
        launch_args+=("$electron_bin" "$DESKTOP_DIR")
    fi

    # Headless wrapper: on Linux, prepend xvfb-run unless SHOW_UI=1 is set.
    local wrapper=()
    if [ "${SHOW_UI:-0}" != "1" ] && [ "$(detect_platform)" = "linux" ]; then
        if command -v xvfb-run >/dev/null 2>&1; then
            wrapper=(xvfb-run -a)
            log_info "Running headless (xvfb-run). Set SHOW_UI=1 to show the window."
        else
            log_info "SHOW_UI not set but xvfb-run is not installed; running with visible UI. Install xvfb to run headless (e.g. 'apt install xvfb')."
        fi
    fi

    PHOTOSPHERE_TEST_MODE=1 \
    PHOTOSPHERE_CONFIG_DIR="$tmp_dir/config" \
    PHOTOSPHERE_VAULT_DIR="$tmp_dir/vault" \
    PHOTOSPHERE_VAULT_TYPE=plaintext \
    PHOTOSPHERE_LOG_DIR="$tmp_dir" \
    PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
    TEST_TMP_DIR="$tmp_dir" \
    NODE_ENV=testing \
    "${wrapper[@]}" "${launch_args[@]}" --no-sandbox --disable-gpu -geometry "${PHOTOSPHERE_TEST_GEOMETRY:-960x800+${x_pos}+0}" > "$tmp_dir/app.log" 2>&1 &
    echo $! > "$tmp_dir/app.pid"

    local actual_port
    # wait_for_test_port prints the port on stdout so it stays return-based (exit would only kill the
    # command-substitution subshell); this guard is what makes a start failure fatal to the test.
    actual_port=$(wait_for_test_port "$tmp_dir/test-control.port") || exit 1
    APP_PORT="$actual_port"
    # Remember how to relaunch this instance so wait_for_ready can recover a startup that binds its
    # control server but never reaches /ready (a rare Electron wedge under concurrent load).
    APP_TMP_DIR="$tmp_dir"
    APP_X_POS="$x_pos"
    log_info "App started (PID $(cat "$tmp_dir/app.pid"), port $actual_port)"
}

# Kills the app process recorded in <tmp_dir>/app.pid. Used by the wait_for_ready relaunch path.
_kill_app() {
    local tmp_dir="$1"
    local pid_file="$tmp_dir/app.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

#
# Polls GET /ready until the app is ready. On a timeout it relaunches the app and retries: under
# heavy concurrent load an Electron instance occasionally comes up (its control server binds) but
# never reaches /ready, and a fresh launch recovers it. Relaunch uses the globals start_app set
# (APP_PORT/APP_TMP_DIR/APP_X_POS), so this must be called right after the matching start_app. The
# <port> argument is accepted for call compatibility but the live port is always APP_PORT.
# Usage: wait_for_ready <port>
#
wait_for_ready() {
    local max_attempts=2
    local attempt=1
    log_info "Waiting for app to be ready on port $APP_PORT..."
    while [ "$attempt" -le "$max_attempts" ]; do
        local elapsed=0
        while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
            if curl -sf "http://localhost:$APP_PORT/ready" > /dev/null 2>&1; then
                log_info "App is ready"
                return 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        log_error "Timed out waiting for app to be ready after ${DEFAULT_WAIT_TIMEOUT}s (attempt $attempt of $max_attempts)"
        if [ "$attempt" -lt "$max_attempts" ]; then
            log_info "Relaunching app and retrying..."
            _kill_app "$APP_TMP_DIR"
            start_app "$APP_TMP_DIR" "$APP_X_POS"
        fi
        attempt=$((attempt + 1))
    done
    log_error "App failed to become ready after $max_attempts launch attempts"
    # Fatal by construction: a test that never reaches /ready must abort, not fall through to its
    # later assertions and log_success. Not called from a cleanup path, so exit is safe here.
    exit 1
}

#
# Polls app.log until pattern matches or the timeout is reached.
# Tracks a per-log cursor (in $tmp_dir/.log-cursor) so each call only sees lines
# logged after the previous successful match. This avoids races where a repeated
# pattern (e.g. "Databases page loaded" on a re-navigation) matches a stale
# occurrence and returns before the new event has actually fired.
# Usage: wait_for_log <tmp_dir> <pattern> [timeout]
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-$DEFAULT_WAIT_TIMEOUT}"
    local elapsed=0
    local cursor_file="$tmp_dir/.log-cursor"
    local start_line=0
    if [ -f "$cursor_file" ]; then
        start_line=$(cat "$cursor_file")
    fi
    log_info "Waiting for log pattern: $pattern (after line $start_line)"
    while [ "$elapsed" -lt "$timeout" ]; do
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
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for log pattern: $pattern"
    log_error "Last 30 lines of app.log:"
    tail -30 "$tmp_dir/app.log" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
    # Exit the test with non-zero so the runner reports FAIL. Without this the
    # test would keep running on stale state and eventually reach log_success,
    # producing a false-pass.
    exit 1
}

#
# Polls the test control server's get-value for the given data-id until its value contains the
# expected substring. Fails the test on timeout. Use this to wait for a control to reach a known
# state before acting on it: each command the driver receives is handled independently, so a command
# sent into a UI that has not caught up yet can be overtaken by the one after it.
# Usage: wait_for_value <port> <data-id> <expected-substring> [timeout]
#
wait_for_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
    local elapsed=0
    local response=""
    while [ "$elapsed" -lt "$timeout" ]; do
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
# Posts a JSON command to the test control server.
# Usage: send_command <port> <endpoint> [json_body]
#
send_command() {
    local port="$1"
    local endpoint="$2"
    local body
    body="${3}"
    if [ -z "$body" ]; then body="{}"; fi
    local response
    response=$(curl -s -X POST "http://localhost:$port/$endpoint" \
        -H "Content-Type: application/json" \
        -d "$body" 2>&1)
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        log_error "curl failed (exit $exit_code) posting to $endpoint: $response"
        return 1
    fi
    if echo "$response" | grep -q '"ok":false'; then
        log_error "Command failed: $response"
        return 1
    fi
    return 0
}

#
# Sends /quit, then kills the app process if it does not exit within a few seconds.
# Usage: stop_app <port> <tmp_dir>
#
stop_app() {
    local port="$1"
    local tmp_dir="$2"
    send_command "$port" quit '{}' 2>/dev/null || true
    sleep 2
    local pid_file="$tmp_dir/app.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

#
# Greps app.log for [ERROR] lines and fails if any are found.
# Usage: check_no_errors <tmp_dir>
#
check_no_errors() {
    local tmp_dir="$1"
    if grep -q '\[ERROR\]' "$tmp_dir/app.log" 2>/dev/null; then
        log_error "Errors found in app.log:"
        grep '\[ERROR\]' "$tmp_dir/app.log" | while IFS= read -r line; do
            echo "  $line"
        done
        # Fatal by construction: signalling failure by return let a test print [FAIL], fall through to
        # log_success and exit 0 (a false pass). It is never called from a cleanup path or a command
        # substitution, so exit is safe and makes an error in app.log fail the test outright.
        exit 1
    fi
    log_success "No errors in app.log"
    return 0
}
