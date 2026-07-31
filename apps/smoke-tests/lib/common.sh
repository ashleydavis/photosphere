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

# Name of the app's database-list config inside its storage sandbox, the mobile counterpart of
# desktop's ~/.config/photosphere/databases.toml. Must match DATABASES_CONFIG_PATH in
# packages/mobile-frontend/src/lib/mobile-databases-config-file.ts, which is what the app reads.
DATABASES_CONFIG_FILE="databases.toml"

# The address every host-side command uses to reach the control bridge. This is the literal IPv4
# loopback address and must never be the name "localhost".
#
# The bridge listens on 0.0.0.0, which is IPv4 only. curl carries its own built-in mapping of the
# name "localhost" to both ::1 and 127.0.0.1 and tries IPv6 first, whatever /etc/hosts and
# getaddrinfo say, so the name and the literal are not interchangeable here.
#
# The bridge binds an OS-assigned port from the ephemeral range, and each Android emulator's QEMU
# process holds console ports on [::1] drawn from that same range. Binding 0.0.0.0:P while [::1]:P is
# already held succeeds, because they are different address families, so the two legitimately end up
# sharing a port number. Probing by name then reaches the emulator console rather than the bridge:
# the connection succeeds, so curl never falls back to IPv4, and the console is not an HTTP server,
# so every probe fails for the full timeout while the bridge sits there healthy. That is the
# BRIDGE-START-BIND flake in docs/flaky-tests-registry.md, reproduced 7 times.
BRIDGE_HOST="127.0.0.1"

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
# Dumps everything known about a bridge port that would not answer, so the cause is recorded at the
# moment of failure rather than guessed at afterwards. Prints curl's own message for one last
# verbose probe, what is actually bound to the port and by which process, what the bridge process is
# doing, what localhost resolved to, and the machine's load and memory.
#
# Every occurrence of this failure so far has left nothing behind but "did not answer", which is not
# enough to tell "the socket is gone" from "the socket is listening but something else owns it" from
# "the probe never reached it". Those are three different bugs.
#
# Usage: dump_bridge_failure_evidence <port> <bridge_pid>
#
dump_bridge_failure_evidence() {
    local port="$1"
    local bridge_pid="$2"

    log_error "--- bridge failure evidence for port $port ---"

    # One last probe with curl's stderr kept, so its own words are recorded alongside the exit code.
    # The polling loop above discards output; this single attempt does not.
    local verbose_output
    verbose_output=$(curl -sS -o /dev/null "http://localhost:$port/ready" 2>&1)
    log_error "curl via localhost: exit $? -- $(echo "$verbose_output" | tr '\n' ' ')"

    # The same probe against the literal loopback address. The bridge binds 0.0.0.0, so if this
    # succeeds where the name did not, the fault is in what localhost resolved to.
    verbose_output=$(curl -sS -o /dev/null "http://127.0.0.1:$port/ready" 2>&1)
    log_error "curl via 127.0.0.1: exit $? -- $(echo "$verbose_output" | tr '\n' ' ')"

    # And explicitly over IPv6. curl carries its own built-in mapping of the name localhost to both
    # ::1 and 127.0.0.1 and tries IPv6 first, whatever /etc/hosts and getaddrinfo say, so the name
    # and the IPv4 literal are not interchangeable here. The bridge listens on 0.0.0.0, which is
    # IPv4 only, so anything answering on ::1 at this port is a different process.
    verbose_output=$(curl -sS -o /dev/null "http://[::1]:$port/ready" 2>&1)
    log_error "curl via [::1]: exit $? -- $(echo "$verbose_output" | tr '\n' ' ')"

    # Everything bound to that port, listening or otherwise, with the owning process. This is what
    # separates a vanished socket from a socket owned by a process that is not the bridge.
    if command -v ss > /dev/null 2>&1; then
        log_error "ss -ltnp on port $port:"
        ss -ltnp "sport = :$port" 2>&1 | while IFS= read -r socket_line; do
            echo "  $socket_line"
        done
        log_error "ss -tnp (any state) on port $port:"
        ss -tnp "sport = :$port or dport = :$port" 2>&1 | while IFS= read -r socket_line; do
            echo "  $socket_line"
        done
    elif command -v netstat > /dev/null 2>&1; then
        log_error "netstat -ltnp filtered to port $port:"
        netstat -ltnp 2>&1 | grep ":$port " | while IFS= read -r socket_line; do
            echo "  $socket_line"
        done
    else
        log_error "Neither ss nor netstat is available, so socket state was not captured."
    fi

    if command -v lsof > /dev/null 2>&1; then
        log_error "lsof -i :$port:"
        lsof -nP -i ":$port" 2>&1 | while IFS= read -r socket_line; do
            echo "  $socket_line"
        done
    fi

    # What the bridge process itself is doing. A process in D state, or one against its descriptor
    # limit, is a different fault from one sitting idle in S with a socket nobody can reach.
    if [ -n "$bridge_pid" ]; then
        log_error "ps for bridge PID $bridge_pid:"
        ps -o pid,ppid,stat,wchan:20,etime,rss,args -p "$bridge_pid" 2>&1 | while IFS= read -r process_line; do
            echo "  $process_line"
        done
        if [ -r "/proc/$bridge_pid/status" ]; then
            log_error "/proc/$bridge_pid/status (State, Threads, FDSize):"
            grep -E '^(State|Threads|FDSize):' "/proc/$bridge_pid/status" 2>&1 | while IFS= read -r status_line; do
                echo "  $status_line"
            done
            log_error "open descriptors: $(ls "/proc/$bridge_pid/fd" 2>/dev/null | wc -l)"
        else
            log_error "No /proc/$bridge_pid/status on this platform, so process state was not captured."
        fi
    fi

    # What localhost resolved to for this run. The bridge binds IPv4 only.
    if command -v getent > /dev/null 2>&1; then
        log_error "getent hosts localhost: $(getent hosts localhost 2>&1 | tr '\n' ' ')"
    elif command -v dscacheutil > /dev/null 2>&1; then
        log_error "dscacheutil localhost: $(dscacheutil -q host -a name localhost 2>&1 | tr '\n' ' ')"
    else
        log_error "No getent or dscacheutil, so localhost resolution was not captured."
    fi

    # The load the failure happened under, so "the machine was hammered" can be settled rather than
    # argued about.
    log_error "loadavg: $(cat /proc/loadavg 2>/dev/null || uptime)"
    log_error "memory: $(free -m 2>/dev/null | awk '/^Mem:/ { print "mem used " $3 "M free " $4 "M avail " $7 "M" } /^Swap:/ { print "swap used " $3 "M free " $4 "M" }' | tr '\n' ' ')"
    log_error "--- end bridge failure evidence ---"
}

#
# Polls the control bridge port until it accepts HTTP connections (any response, including the
# 503 returned by /ready before the app is up).
#
# Also watches the bridge process itself, and says what actually went wrong.
#
# Without that this reports "Control bridge did not start" for a bridge that demonstrably did start:
# bridge.log holds its own "Control bridge listening on port N" line and bridge.port holds the port it
# bound, yet the message sends you looking for a startup or a port-binding problem that never happened.
# That has cost four separate investigations. The two cases are now told apart: a bridge that exited is
# reported immediately with whatever it printed, rather than after a 40 second wait for a process that
# is not there to answer; a bridge still running when the clock runs out is reported as unreachable,
# which is a different fault with a different cause.
#
# curl's exit status is kept from the last attempt and printed, because "unreachable" covers connection
# refused, a name that would not resolve and a hang, and those are not the same problem either.
#
# Usage: wait_for_bridge <port> <tmp_dir>
#
wait_for_bridge() {
    local port="$1"
    local tmp_dir="${2:-}"
    local pid_file="$tmp_dir/bridge.pid"
    local ticks=$((DEFAULT_BRIDGE_TIMEOUT * POLL_TICKS_PER_SECOND))
    local curl_status=0
    local bridge_pid=""
    # How many probes actually ran, and when the wait began. The timeout is 40s at a 0.2s poll, which
    # is 200 attempts only if each probe returns promptly. curl here has no timeout of its own, so a
    # probe that connects and then waits forever for a reply blocks the loop, and the whole 40s is
    # one hung attempt rather than 200 refused ones. Those are opposite faults: the first means the
    # bridge accepted the connection and never answered, the second means nothing accepted it at all.
    # Counting the attempts is what tells them apart.
    local attempts=0
    local started_at=$SECONDS

    if [ -n "$tmp_dir" ] && [ -f "$pid_file" ]; then
        bridge_pid="$(cat "$pid_file" 2>/dev/null)"
    fi

    while [ "$ticks" -gt 0 ]; do
        attempts=$((attempts + 1))
        # curl's status has to be captured from the condition itself. Reading $? on the line after
        # `fi` reads the status of the `if` compound command (0 when the condition failed and there
        # is no else), so every failure used to report "last curl exit 0", which is impossible.
        curl -s -o /dev/null "http://$BRIDGE_HOST:$port/ready" 2>/dev/null && return 0
        curl_status=$?

        if [ -n "$bridge_pid" ] && ! kill -0 "$bridge_pid" 2>/dev/null; then
            log_error "The control bridge (PID $bridge_pid) exited before it answered on port $port."
            if [ -s "$tmp_dir/bridge.log" ]; then
                log_error "What the bridge printed before it went:"
                while IFS= read -r bridge_line; do
                    echo "  $bridge_line"
                done < "$tmp_dir/bridge.log"
            else
                log_error "It printed nothing to $tmp_dir/bridge.log."
            fi
            exit 1
        fi

        sleep "$POLL_INTERVAL_SECONDS"
        ticks=$((ticks - 1))
    done

    if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
        log_error "The control bridge (PID $bridge_pid) is still running but did not answer on port $port within ${DEFAULT_BRIDGE_TIMEOUT}s (last curl exit $curl_status, $attempts probes in $((SECONDS - started_at))s)."
        if [ -s "$tmp_dir/bridge.log" ]; then
            log_error "What the bridge printed:"
            while IFS= read -r bridge_line; do
                echo "  $bridge_line"
            done < "$tmp_dir/bridge.log"
        fi
        dump_bridge_failure_evidence "$port" "$bridge_pid"
        exit 1
    fi

    log_error "Control bridge did not start on port $port within ${DEFAULT_BRIDGE_TIMEOUT}s (last curl exit $curl_status, $attempts probes in $((SECONDS - started_at))s)"
    dump_bridge_failure_evidence "$port" "$bridge_pid"
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

    wait_for_bridge "$actual_port" "$tmp_dir"

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
            if curl -sf "http://$BRIDGE_HOST:$port/ready" > /dev/null 2>&1; then
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
    response=$(curl -s -w '\n%{http_code}' -X POST "http://$BRIDGE_HOST:$port/$endpoint" \
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
    response=$(curl -sf "http://$BRIDGE_HOST:$port/get-value?dataId=$data_id" 2>/dev/null || true)
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
# than being silently dropped. Stdout passes straight through, so callers can capture it, and
# nothing else this spawns is allowed to hold that stream open (see the note on the killer below).
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
    # The killer's own output goes to /dev/null, and this is load-bearing rather than tidiness. A
    # background job inherits the caller's stdout, so when the caller is a pipeline or a $( ) capture
    # the killer holds the write end of that pipe open. The reader then sees no end-of-file until the
    # sleep expires, and the whole call takes the full timeout however fast the command was. That is
    # what turned every iOS test into a flat 600 seconds and ran the job into its 90 minute limit.
    ( sleep "$seconds" && kill "$child_pid" 2>/dev/null ) >/dev/null 2>&1 &
    local killer_pid=$!
    wait "$child_pid"
    local child_status=$?
    kill "$killer_pid" 2>/dev/null
    # The sleep is a child of the killer and outlives it, so it is stopped too rather than left to
    # expire in its own time.
    pkill -P "$killer_pid" 2>/dev/null || true
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
