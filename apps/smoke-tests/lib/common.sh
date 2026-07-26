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

# Name of the per-test scratch directory, relative to the test's own directory. Every test sets
# TMP_DIR from this rather than hardcoding "tmp", so that several suites running at once out of one
# checkout each get their own scratch space. The runner sets it to tmp/run-<id> per run; on its own
# it stays "tmp", which is what a single run has always used.
#
# Without this, two concurrent runs share tests/<name>/tmp, and the runner wiping that directory
# before a test destroys the other run's live bridge log and pid file underneath it.
TEST_TMP_NAME="${PHOTOSPHERE_TEST_TMP:-tmp}"

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

# How long each poll of a wait helper sleeps, and how many of those make a second. A one second poll
# meant every wait overshot by half a second on average, and a test performs many waits, so most of a
# run was spent asleep after the thing being waited for had already happened. Timeouts stay expressed
# in seconds at every call site: the helpers convert them to ticks.
POLL_INTERVAL_SECONDS=0.2
POLL_TICKS_PER_SECOND=5

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
    local ticks=$((DEFAULT_BRIDGE_TIMEOUT * POLL_TICKS_PER_SECOND))
    while [ "$ticks" -gt 0 ]; do
        if [ -s "$port_file" ]; then
            cat "$port_file"
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
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
    local ticks=$((DEFAULT_BRIDGE_TIMEOUT * POLL_TICKS_PER_SECOND))
    while [ "$ticks" -gt 0 ]; do
        if curl -s -o /dev/null "http://localhost:$port/ready" 2>/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
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

    # app.log is appended across every launch within a test, and wait_for_log's cursor is a line number
    # into that one file. A wait after a restart must never match a line the PREVIOUS launch wrote:
    # test 39 restarted the app, matched the outgoing launch's trailing "Secrets page loaded" (written
    # after the cursor when that launch re-rendered), and then read a value before the relaunched app had
    # rendered anything, reading empty. Parking the cursor at the current end of app.log makes every wait
    # after this launch see only this launch's lines. awk counts a trailing unterminated line, which
    # wc -l would miss and so leave one stale line matchable.
    local existing_log_lines=0
    if [ -f "$tmp_dir/app.log" ]; then
        existing_log_lines=$(awk 'END { print NR }' "$tmp_dir/app.log")
    fi
    echo "$existing_log_lines" > "$tmp_dir/.log-cursor"

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
        local ticks=$((DEFAULT_WAIT_TIMEOUT * POLL_TICKS_PER_SECOND))
        while [ "$ticks" -gt 0 ]; do
            if curl -sf "http://localhost:$port/ready" > /dev/null 2>&1; then
                log_info "App is ready"
                return 0
            fi
            sleep "$POLL_INTERVAL_SECONDS"
            ticks=$((ticks - 1))
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
# Usage: wait_for_log <tmp_dir> <pattern> [timeout]
#
wait_for_log() {
    local tmp_dir="$1"
    local pattern="$2"
    local timeout="${3:-$DEFAULT_WAIT_TIMEOUT}"
    local ticks=$((timeout * POLL_TICKS_PER_SECOND))
    local cursor_file="$tmp_dir/.log-cursor"
    local start_line=0
    if [ -f "$cursor_file" ]; then
        start_line=$(cat "$cursor_file")
    fi
    log_info "Waiting for log pattern: $pattern (after line $start_line)"
    while [ "$ticks" -gt 0 ]; do
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
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
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
    # The trailing status code lets an unroutable endpoint be caught. Without it a POST to a route the
    # bridge does not register returns Express's 404 HTML page, which curl reports as success and which
    # contains no '"ok":false', so an unimplemented command silently "passed" and the test only failed
    # later on the effect that never happened.
    response=$(curl -s -w '\n%{http_code}' -X POST "http://localhost:$port/$endpoint" \
        -H "Content-Type: application/json" \
        -d "$body" 2>&1)
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        log_error "curl failed (exit $exit_code) posting to $endpoint: $response"
        return 1
    fi
    local status_code
    status_code=$(echo "$response" | tail -1)
    local body_text
    body_text=$(echo "$response" | sed '$d')
    if [ "$status_code" != "200" ]; then
        log_error "Command $endpoint failed with HTTP $status_code: $body_text"
        return 1
    fi
    if echo "$body_text" | grep -q '"ok":false'; then
        log_error "Command failed: $body_text"
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
# Reads the current value of the element with the given data-id via the control bridge's /get-value
# endpoint, echoing the value to stdout (empty when the element is absent). Value-returning helper:
# it prints and never exits, so it is safe inside $(...). getValue returns '' for a missing element.
# Usage: read_value <port> <dataId>
#
read_value() {
    local port="$1"
    local data_id="$2"
    local response
    response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
    # grep -o only prints matches, so on no match nothing is echoed (avoiding sed's echo-on-no-match).
    echo "$response" | grep -o '"value":"[^"]*"' | head -n1 | sed 's/^"value":"//; s/"$//'
}

#
# Polls /get-value until the element's value matches expected_regex (extended regex), failing with
# exit 1 if it never does within the timeout. An empty value is always a miss (a missing element
# reads as ''). Asserting helper: it exits and prints nothing capturable, so do NOT use it in $(...).
# Usage: wait_for_value <port> <dataId> <expected_regex> [timeout_seconds]
#
wait_for_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
    local ticks=$((timeout * POLL_TICKS_PER_SECOND))
    local value=""
    while [ "$ticks" -gt 0 ]; do
        value=$(read_value "$port" "$data_id")
        if [ -n "$value" ] && echo "$value" | grep -qE "$expected"; then
            log_success "Value for '$data_id' matched /$expected/: $value"
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
    done
    log_error "Timed out waiting for '$data_id' to match /$expected/ (last value: '${value:-}')"
    exit 1
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

# Adds a secret through the real Add Secret UI (not a test backdoor), so a test that needs a
# pre-existing secret creates it the same way a user would. Assumes the Secrets page is already open.
# Args: port, name, type (s3-credentials|encryption-key|api-key), value.
# The value maps to the one field the tests read back: the S3 region for s3-credentials, or the API
# key for api-key. encryption-key is created with an empty PEM (its tests only re-save it, never read
# the value), because the driver cannot type into the PEM textarea (it targets <input>, not <textarea>).
add_secret_via_ui() {
    local port="$1"
    local name="$2"
    local secret_type="$3"
    local value="$4"

    send_command "$port" click '{"dataId":"add-secret-button"}' || return 1
    wait_for_log "$TMP_DIR" "Add secret dialog opened"
    send_command "$port" type "{\"dataId\":\"secret-name-input\",\"text\":\"$name\"}" || return 1

    # The type defaults to s3-credentials; only switch it when a different type is asked for. The click
    # command waits for the option to render in the opened listbox before clicking it.
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
            # No value field driven; created with an empty PEM (see the header note).
            ;;
    esac

    send_command "$port" click '{"dataId":"add-secret-confirm"}' || return 1
    wait_for_log "$TMP_DIR" "Secret added"
}

#
# Runs a command under a wall-clock cap, so a wedged process cannot hang the whole suite.
#
# GNU `timeout` does not exist on macOS, where the iOS suite runs: invoking it there failed the
# command outright with "timeout: command not found" rather than capping it. coreutils installs the
# same tool as `gtimeout`, so prefer whichever is present, and fall back to a background process plus
# a killer (the approach apps/desktop/smoke-tests.sh already uses) so the cap exists either way rather
# than being silently dropped. Stdout passes straight through, so callers can capture it.
# Usage: run_with_timeout <seconds> <command...>
#
run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5 "$seconds" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout --kill-after=5 "$seconds" "$@"
        return $?
    fi
    "$@" &
    local child_pid=$!
    ( sleep "$seconds" && kill "$child_pid" 2>/dev/null ) &
    local killer_pid=$!
    wait "$child_pid"
    local child_status=$?
    kill "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    return $child_status
}

#
# Runs the psi CLI from source against a vault and config isolated under the test's own tmp dir, so a
# test never reads or writes the developer's real OS keychain or database list. Both variables are
# required for isolation: PHOTOSPHERE_VAULT_DIR alone still selects the keychain vault, because
# getDefaultVaultType defaults to "keychain" unless PHOTOSPHERE_VAULT_TYPE says otherwise. stdin is
# closed so an unexpected interactive prompt aborts instead of hanging the run, and NO_COLOR keeps
# the output greppable. Usage: run_cli <tmp_dir> <cli args...>
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
# Fails the test unless the Android emulator is attached to the host LAN bridge. Host-to-device LAN
# sharing needs it: under QEMU's default user-mode NAT the guest's discovery broadcast never reaches
# the host and the host cannot open the return connection, so a host-side sender would silently wait
# out its full 60-second timeout and exit 0. Detected from the guest's wlan0 address, the same signal
# android_host_address uses. A no-op off Android, where the simulator shares the host's network.
# Usage: require_lan_bridge
#
require_lan_bridge() {
    if [ "$PLATFORM" != "android" ]; then
        return 0
    fi
    if adb shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
        log_success "Emulator is on the host LAN bridge."
        return 0
    fi
    # A run that has declared it cannot have a bridge skips these tests instead of failing, the same
    # way 33-s3-database skips without S3 credentials. The release workflow sets this because its
    # emulator is booted by an action that attaches no tap device, so the bridge cannot be built
    # there at all. A developer who simply forgot to bring the bridge up still gets a hard failure.
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ]; then
        log_info "SKIP: this test needs the host LAN bridge and PHOTOSPHERE_NO_LAN_BRIDGE=1 says this run has none. Skipping."
        exit 0
    fi
    log_error "The emulator is not on the host LAN bridge, so a host-to-device LAN transfer cannot work."
    log_error "Bring it up with: bun run emu:and:up"
    exit 1
}

#
# Runs a psi CLI LAN send and fails the test unless it reports a successful transfer. The exit code
# alone is NOT a usable signal: when the sender never discovers a receiver it prints "No device found
# within 60 seconds." and still exits 0, so a silent non-delivery would pass. Asserting on the
# success line is what makes a failed transfer fail the test. run_cli caps the send with `timeout` so
# a wedged sender cannot hang the suite. Output is written to <tmp_dir>/sender.log and dumped on
# failure. Usage: cli_send_expect_success <tmp_dir> <cli args...>
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
# Asserts immediately (no polling) that the element's value matches <expected_regex>, exiting 1
# otherwise. An empty value never matches. Usage: assert_value <port> <dataId> <expected_regex>
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

# Load the platform launcher when this file is sourced.
load_platform
