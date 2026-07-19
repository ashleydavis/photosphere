#!/bin/bash

# Shared helpers for host-driven UI smoke tests.
# Source this file from each test.sh:
#   source "$TEST_DIR/../lib/common.sh"
# Selects the platform launcher (android.sh or ios.sh today; an electron.sh could be added
# later) from the PLATFORM env var. The control bridge and these helpers are platform-neutral.
#
# Unlike the desktop in-app smoke tests, a mobile app has no in-process control server, so
# start_app also
# starts the host control bridge (a Bun process) which presents the same HTTP command surface
# and relays commands to the app over a WebSocket. The bridge writes app-forwarded log lines to
# $tmp_dir/app.log in the same [LEVEL] format the desktop app uses, so wait_for_log and
# check_no_errors below work unchanged.

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directory containing this script (apps/smoke-tests/lib).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repo-relative locations used by the platform launchers.
SMOKE_TESTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
REPO_DIR="$(cd "$SMOKE_TESTS_DIR/../.." && pwd)"
ANDROID_FRONTEND_DIR="$REPO_DIR/apps/android-frontend"
IOS_FRONTEND_DIR="$REPO_DIR/apps/ios-frontend"

# The application id / bundle id of both native projects.
APP_ID="au.com.codecapers.photosphere"
BUNDLE_ID="au.com.codecapers.photosphere"

# Default seconds a wait tolerates before failing, doubled from the standalone value so a concurrent
# suite run sharing the machine (which slows everything) does not trip a spurious timeout.
DEFAULT_WAIT_TIMEOUT=120

# Shorter default (also doubled) for the bridge startup waits.
DEFAULT_BRIDGE_TIMEOUT=40

# Clean up the app/bridge even when a run is interrupted (Ctrl-C) or the runner's timeout kills a
# slow test (SIGTERM), not only on a normal exit. A bash EXIT trap does not fire on an uncaught
# signal, so turn those signals into an exit here: that runs the per-test EXIT trap (stop_app),
# leaving nothing orphaned. (A hard SIGKILL still cannot be caught, but that is not the normal path.)
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
# Selects and sources the platform launcher for the current PLATFORM (android or ios).
#
load_platform() {
    if [ -z "${PLATFORM:-}" ]; then
        log_error "PLATFORM env var must be set to 'android' or 'ios'"
        exit 1
    fi
    case "$PLATFORM" in
        android) source "$LIB_DIR/android.sh" ;;
        ios)     source "$LIB_DIR/ios.sh" ;;
        *)
            log_error "Unknown PLATFORM: $PLATFORM (expected 'android' or 'ios')"
            exit 1
            ;;
    esac
}

#
# Waits for the bridge to publish the port it actually bound and prints it. The bridge may bind a
# port other than the one requested (it falls back to an OS-assigned port if the requested port was
# taken by a parallel run), so the real port has to be read back rather than assumed.
# Usage: wait_for_bridge_port <port_file>
#
wait_for_bridge_port() {
    local port_file="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$DEFAULT_BRIDGE_TIMEOUT" ]; do
        if [ -s "$port_file" ]; then
            cat "$port_file"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Control bridge did not report a listening port within ${DEFAULT_BRIDGE_TIMEOUT}s"
    return 1
}

#
# Polls the control bridge port until it accepts HTTP connections (any response, including the
# 503 returned by /ready before the app is up).
#
wait_for_bridge() {
    local port="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$DEFAULT_BRIDGE_TIMEOUT" ]; do
        if curl -s -o /dev/null "http://localhost:$port/ready" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Control bridge did not start on port $port within ${DEFAULT_BRIDGE_TIMEOUT}s"
    exit 1
}

#
# Starts the control bridge (Bun process) writing to $tmp_dir/app.log, then launches the app
# on the selected platform wired to the bridge. The bridge binds an OS-assigned free port (never a
# pre-picked number, which could collide with a parallel run); this reads that port back and
# publishes it as APP_PORT (the global every test uses) so the app launch and all later commands
# target it.
# Usage: start_app <tmp_dir>
#
start_app() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir"
    # Clear any stale port file from a previous run so wait_for_bridge_port reads this run's port.
    rm -f "$tmp_dir/bridge.port"

    PHOTOSPHERE_TEST_PORT="0" \
    PHOTOSPHERE_LOG_DIR="$tmp_dir" \
    PHOTOSPHERE_TEST_PLATFORM="$PLATFORM" \
    PHOTOSPHERE_TEST_APP_ID="$APP_ID" \
    PHOTOSPHERE_TEST_BUNDLE_ID="$BUNDLE_ID" \
    PHOTOSPHERE_TEST_IOS_UDID="${IOS_SIMULATOR_UDID:-}" \
    bun "$LIB_DIR/control-bridge-main.ts" > "$tmp_dir/bridge.log" 2>&1 &
    local bridge_pid=$!
    # Remove the bridge from the shell's job table so killing it in stop_app does not print an
    # asynchronous "Terminated: 15" job-control notice. It is still stopped explicitly by PID.
    disown "$bridge_pid"
    echo "$bridge_pid" > "$tmp_dir/bridge.pid"

    local actual_port
    actual_port=$(wait_for_bridge_port "$tmp_dir/bridge.port") || exit 1
    APP_PORT="$actual_port"
    log_info "Control bridge started (PID $bridge_pid, port $actual_port)"

    wait_for_bridge "$actual_port"

    # The platform launcher installs and launches the app pointed at the bridge port.
    "${PLATFORM}_launch" "$actual_port"
    log_info "App launched on $PLATFORM (port $actual_port)"
}

#
# Polls GET /ready until the app is ready or the timeout is reached, relaunching the app between
# attempts. On a cold CI emulator/simulator the app's WebView occasionally never connects to the
# control bridge (observed as a "No app connected to control bridge" stall); force-stopping and
# relaunching recovers it. This runs before any test actions, so a relaunch is always safe.
# Usage: wait_for_ready <port> [max_attempts]
#
wait_for_ready() {
    local port="$1"
    local max_attempts="${2:-2}"
    local attempt=1
    log_info "Waiting for app to be ready on port $port..."
    while [ "$attempt" -le "$max_attempts" ]; do
        local elapsed=0
        while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
            if curl -sf "http://localhost:$port/ready" > /dev/null 2>&1; then
                log_info "App is ready"
                return 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        log_error "Timed out waiting for app to be ready after ${DEFAULT_WAIT_TIMEOUT}s (attempt $attempt of $max_attempts)"
        if [ "$attempt" -lt "$max_attempts" ]; then
            log_info "Relaunching app on port $port and retrying..."
            "${PLATFORM}_stop" "$port" || true
            "${PLATFORM}_launch" "$port"
        fi
        attempt=$((attempt + 1))
    done
    log_error "App failed to become ready after $max_attempts launch attempts"
    exit 1
}

#
# Polls app.log until pattern matches or the timeout is reached.
# Tracks a per-log cursor (in $tmp_dir/.log-cursor) so each call only sees lines logged after
# the previous successful match.
# Usage: wait_for_log <tmp_dir> <pattern>
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local elapsed=0
    local cursor_file="$tmp_dir/.log-cursor"
    local start_line=0
    if [ -f "$cursor_file" ]; then
        start_line=$(cat "$cursor_file")
    fi
    log_info "Waiting for log pattern: $pattern (after line $start_line)"
    while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
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
    exit 1
}

#
# Posts a JSON command to the control bridge.
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
# Sends /quit (bridge stops the app host-side), then stops the app and kills the bridge.
# Usage: stop_app <port> <tmp_dir>
#
stop_app() {
    local port="$1"
    local tmp_dir="$2"
    send_command "$port" quit '{}' 2>/dev/null || true
    "${PLATFORM}_stop" "$port" 2>/dev/null || true
    local pid_file="$tmp_dir/bridge.pid"
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
# Greps app.log for [ERROR] lines and fails if any are found. An optional second argument is an
# extended-regex of [ERROR] lines to ignore (for errors that belong to a separate, not-yet-built
# layer the test deliberately does not cover); any remaining [ERROR] line still fails the check.
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
        exit 1
    fi
    log_success "No errors in app.log"
    return 0
}

#
# Creates a database on the host via the CLI at the given path, importing any image files passed
# after the path. Mirrors how the desktop smoke tests pre-create their databases (the CLI does the
# host-side image processing the mobile device cannot do yet). The database is created under the
# test's own tmp dir and then seeded onto the device with ${PLATFORM}_seed_database.
# Usage: create_database <db_path> [image ...]
#
create_database() {
    local db_path="$1"
    shift
    ( cd "$REPO_DIR/apps/cli" && bun run start -- init --db "$db_path" --yes ) >/dev/null 2>&1
    local image
    for image in "$@"; do
        ( cd "$REPO_DIR/apps/cli" && bun run start -- add "$image" --db "$db_path" --yes ) >/dev/null 2>&1
    done
}

# Load the platform launcher when this file is sourced.
load_platform
