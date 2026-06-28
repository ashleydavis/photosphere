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
# Finds a free TCP port using Python.
#
find_free_port() {
    python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
port = s.getsockname()[1]
s.close()
print(port)
"
}

#
# Selects and sources the platform launcher for the current PLATFORM (android or ios).
#
load_platform() {
    if [ -z "${PLATFORM:-}" ]; then
        log_error "PLATFORM env var must be set to 'android' or 'ios'"
        return 1
    fi
    case "$PLATFORM" in
        android) source "$LIB_DIR/android.sh" ;;
        ios)     source "$LIB_DIR/ios.sh" ;;
        *)
            log_error "Unknown PLATFORM: $PLATFORM (expected 'android' or 'ios')"
            return 1
            ;;
    esac
}

#
# Polls the control bridge port until it accepts HTTP connections (any response, including the
# 503 returned by /ready before the app is up).
#
wait_for_bridge() {
    local port="$1"
    local timeout="${2:-20}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -s -o /dev/null "http://localhost:$port/ready" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Control bridge did not start on port $port within ${timeout}s"
    return 1
}

#
# Starts the control bridge (Bun process) writing to $tmp_dir/app.log, then launches the app
# on the selected platform wired to the bridge.
# Usage: start_app <port> <tmp_dir>
#
start_app() {
    local port="$1"
    local tmp_dir="$2"
    mkdir -p "$tmp_dir"

    PHOTOSPHERE_TEST_PORT="$port" \
    PHOTOSPHERE_LOG_DIR="$tmp_dir" \
    PHOTOSPHERE_TEST_PLATFORM="$PLATFORM" \
    PHOTOSPHERE_TEST_APP_ID="$APP_ID" \
    PHOTOSPHERE_TEST_BUNDLE_ID="$BUNDLE_ID" \
    PHOTOSPHERE_TEST_IOS_UDID="${IOS_SIMULATOR_UDID:-}" \
    bun "$LIB_DIR/control-bridge-main.ts" > "$tmp_dir/bridge.log" 2>&1 &
    echo $! > "$tmp_dir/bridge.pid"
    log_info "Control bridge started (PID $(cat "$tmp_dir/bridge.pid"), port $port)"

    wait_for_bridge "$port"

    # The platform launcher installs and launches the app pointed at the bridge port.
    "${PLATFORM}_launch" "$port"
    log_info "App launched on $PLATFORM (port $port)"
}

#
# Polls GET /ready until the app is ready or the timeout is reached.
# Usage: wait_for_ready <port> [timeout_secs]
#
wait_for_ready() {
    local port="$1"
    local timeout="${2:-60}"
    local elapsed=0
    log_info "Waiting for app to be ready on port $port..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sf "http://localhost:$port/ready" > /dev/null 2>&1; then
            log_info "App is ready"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for app to be ready after ${timeout}s"
    return 1
}

#
# Polls app.log until pattern matches or the timeout is reached.
# Tracks a per-log cursor (in $tmp_dir/.log-cursor) so each call only sees lines logged after
# the previous successful match.
# Usage: wait_for_log <tmp_dir> <pattern> [timeout_secs]
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-60}"
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
        return 1
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
