#!/bin/bash

# Shared helpers for Electron smoke tests.
# Source this file from each test.sh:
#   source "$TEST_DIR/../lib/common.sh"
# Expects DESKTOP_DIR to be set to the apps/desktop directory.

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

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
# Launches the Electron app in test mode as a background process.
# Usage: start_app <port> <tmp_dir> [x_position]
#
start_app() {
    local port="$1"
    local tmp_dir="$2"
    local x_pos="${3:-0}"
    mkdir -p "$tmp_dir"
    local launch_args=()
    if [ "${USE_BINARY:-false}" = "true" ]; then
        launch_args+=("$(get_release_binary)")
    else
        local electron_bin
        electron_bin=$(cd "$DESKTOP_DIR" && node -e "process.stdout.write(require('electron'))")
        launch_args+=("$electron_bin" "$DESKTOP_DIR")
    fi
    PHOTOSPHERE_TEST_MODE=1 \
    PHOTOSPHERE_TEST_PORT="$port" \
    PHOTOSPHERE_CONFIG_DIR="$tmp_dir/config" \
    PHOTOSPHERE_VAULT_DIR="$tmp_dir/vault" \
    PHOTOSPHERE_VAULT_TYPE=plaintext \
    PHOTOSPHERE_LOG_DIR="$tmp_dir" \
    TEST_TMP_DIR="$tmp_dir" \
    NODE_ENV=testing \
    "${launch_args[@]}" --no-sandbox --disable-gpu -geometry "960x800+${x_pos}+0" > "$tmp_dir/app.log" 2>&1 &
    echo $! > "$tmp_dir/app.pid"
    log_info "App started (PID $(cat "$tmp_dir/app.pid"), port $port)"
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
# Usage: wait_for_log <tmp_dir> <pattern> [timeout_secs]
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-60}"
    local elapsed=0
    log_info "Waiting for log pattern: $pattern"
    while [ "$elapsed" -lt "$timeout" ]; do
        if grep -q "$pattern" "$tmp_dir/app.log" 2>/dev/null; then
            log_info "Found: $pattern"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for log pattern: $pattern"
    log_error "Last 30 lines of app.log:"
    tail -30 "$tmp_dir/app.log" 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done
    return 1
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
        return 1
    fi
    log_success "No errors in app.log"
    return 0
}
