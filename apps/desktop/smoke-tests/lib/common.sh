#!/bin/bash

# Shared helpers for Electron smoke tests.
# Source this file from each test.sh:
#   source "$TEST_DIR/../lib/common.sh"
# Expects DESKTOP_DIR to be set to the apps/desktop directory.

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directory containing this script (apps/desktop/smoke-tests/lib), and the repository it sits in.
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$COMMON_LIB_DIR/../../../.." && pwd)"

# Per-test temporary directories. Every test writes everything it produces inside one directory of
# its own, so no test can be affected by, or affect, another test's files.
source "$REPO_DIR/scripts/lib/allocate-test-temp-dir.sh"

# Starting and stopping background processes: the process group launcher, the tree walk and the
# leak counter. Shared with the mobile suite, the CLI suites and the story player so there is one
# implementation rather than a copy per caller.
source "$REPO_DIR/scripts/lib/process-control.sh"

# Default seconds a wait tolerates before failing, doubled from the standalone value so a concurrent
# suite run sharing the machine (which slows everything) does not trip a spurious timeout.
DEFAULT_WAIT_TIMEOUT=120

# Absolute path to the repository root, for reaching the helper scripts under scripts/. Resolved from
# this file's own location (apps/desktop/smoke-tests/lib) so it does not depend on the caller's cwd.
SMOKE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

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

# TMP_DIR is where a test keeps its app log, pid file, config, vault and anything else it writes.
# smoke-tests.sh allocates it and hands it down in PHOTOSPHERE_TMP_DIR; a test run on its own,
# straight from the command line, allocates its own here so it is isolated either way. Set here
# rather than in each test.sh so isolation holds by construction and no test can forget to ask
# for it.
#
# Converted to a native path because Electron is a native process: on Windows (Git Bash) the POSIX
# form mktemp prints is not a path Electron can resolve.
if [ -n "${PHOTOSPHERE_TMP_DIR:-}" ]; then
    TMP_DIR="$PHOTOSPHERE_TMP_DIR"
else
    TMP_DIR="$(photosphere_test_temp_dir "$(basename "$(dirname "$0")")")"
    photosphere_export_test_temp "$TMP_DIR"
fi
mkdir -p "$TMP_DIR"
TMP_DIR="$(cd "$TMP_DIR" && native_pwd)"

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
# Prints the absolute path of the Electron executable the app in <app-directory> would launch.
#
# The electron npm package records the executable's platform-specific relative path in its path.txt
# ("electron" on Linux, "Electron.app/Contents/MacOS/Electron" on macOS, "electron.exe" on Windows)
# and unpacks the binary under dist/, so the executable is <package>/dist/<contents of path.txt>.
# That is exactly what requiring the package returns.
#
# Bun may hoist the package to the workspace root or keep it in the app's own node_modules, so both
# are checked, nearest first, the way node's resolver would.
#
# Usage: resolve_electron_binary <app-directory>
#
resolve_electron_binary() {
    local app_dir="$1"
    local candidate_dir
    local package_dir
    for candidate_dir in "$app_dir/node_modules/electron" "$app_dir/../../node_modules/electron"; do
        if [ -f "$candidate_dir/path.txt" ]; then
            package_dir=$(cd "$candidate_dir" && native_pwd)
            echo "$package_dir/dist/$(cat "$candidate_dir/path.txt")"
            return 0
        fi
    done
    log_error "Could not find the electron package from $app_dir: no path.txt in $app_dir/node_modules/electron or $app_dir/../../node_modules/electron" >&2
    return 1
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
        electron_bin=$(resolve_electron_binary "$DESKTOP_DIR") || exit 1
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

    # Launched into a process group of its own, and the group recorded beside the pid. The recorded
    # pid is the xvfb-run wrapper, and the app and the X server are its children; once the wrapper
    # dies they are reparented to init and no walk of the process tree can find them again. The
    # group survives that, so it is what cleanup_apps kills. The environment goes through `env`
    # because launch_in_process_group takes a command, and a variable assignment written in front of
    # a shell function is not one.
    # Done here rather than left to the launch below, which runs inside a process substitution: a
    # subshell inherits this shell's variables but cannot write back to it, so the check's result
    # would be forgotten and its probe process spawned again on every single launch.
    if ! process_control_verify_job_control; then
        log_error "Cannot start the app without a process group of its own; see the error above."
        return 1
    fi

    local launched_pid launched_pgid
    read -r launched_pid launched_pgid < <(launch_in_process_group "$tmp_dir/app.log" \
        env PHOTOSPHERE_TEST_MODE=1 \
            PHOTOSPHERE_CONFIG_DIR="$tmp_dir/config" \
            PHOTOSPHERE_VAULT_DIR="$tmp_dir/vault" \
            PHOTOSPHERE_VAULT_TYPE=plaintext \
            PHOTOSPHERE_LOG_DIR="$tmp_dir" \
            PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
            TEST_TMP_DIR="$tmp_dir" \
            NODE_ENV=testing \
            "${wrapper[@]}" "${launch_args[@]}" --no-sandbox --disable-gpu -geometry "${PHOTOSPHERE_TEST_GEOMETRY:-960x800+${x_pos}+0}")
    echo "$launched_pid" > "$tmp_dir/app.pid"
    echo "$launched_pgid" > "$tmp_dir/app.pgid"

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

#
# Stops the app launched from the given tmp directory, and everything it started.
#
# The recorded app pid is the xvfb-run wrapper, not the app. xvfb-run runs its command as a child
# rather than exec'ing it, and starts Xvfb as another child of its own, so signalling that one pid
# leaves both Electron and Xvfb alive and orphaned to init. A SIGKILL to the wrapper is worse than a
# SIGTERM, because it skips xvfb-run's `trap clean_up EXIT`, which is the only thing that would have
# stopped Xvfb.
#
# Left unfixed this leaks a whole Electron process tree and an X server per launch. They accumulated
# across runs and worktrees until the machine ran out of memory and systemd-oomd killed 354 processes
# in one go, which took the Android emulator pool with it and failed a test run that was otherwise fine.
#
# The group recorded by start_app is preferred, because it still reaches the app and the X server
# after the wrapper has died. The tree walk below is only for a tmp directory that has no recorded
# group, which means start_app never got as far as writing one.
# Usage: kill_app_tree <pid> [tmp_dir]
#
kill_app_tree() {
    local pid="$1"
    local tmp_dir="${2:-${APP_TMP_DIR:-}}"
    local pgid=""
    if [ -n "$tmp_dir" ] && [ -f "$tmp_dir/app.pgid" ]; then
        pgid="$(cat "$tmp_dir/app.pgid" 2>/dev/null || true)"
    fi
    if [ -n "$pgid" ]; then
        kill_process_group "$pgid"
        return 0
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill_process_tree "$pid"
    fi
    return 0
}

#
# Stops whatever each of the given tmp directories has running, and is the only thing a test's
# cleanup needs to call. Tolerates a missing pid file, a pid that is already gone and a directory
# that was never used, so it is safe in an unconditional trap and safe to call twice.
#
# Every desktop test cleans up through this, so no test has to know how a process is stopped and a
# change to that can never again reach some tests and miss others.
# Usage: cleanup_apps <tmp_dir> [tmp_dir ...]
#
cleanup_apps() {
    local tmp_dir
    for tmp_dir in "$@"; do
        if [ -z "$tmp_dir" ] || [ ! -d "$tmp_dir" ] || [ ! -f "$tmp_dir/app.pid" ]; then
            continue
        fi
        local pid
        pid="$(cat "$tmp_dir/app.pid" 2>/dev/null || true)"
        kill_app_tree "$pid" "$tmp_dir" || true
    done
    return 0
}

# Kills the app recorded in <tmp_dir>. Used by the wait_for_ready relaunch path.
_kill_app() {
    local tmp_dir="$1"
    cleanup_apps "$tmp_dir"
}

#
# Polls GET /ready until the app is ready. On a timeout it relaunches the app and retries: under
# heavy concurrent load an Electron instance occasionally comes up (its control server binds) but
# never reaches /ready, and a fresh launch recovers it. Relaunch uses the globals start_app set
# (APP_PORT/APP_TMP_DIR/APP_X_POS), so this must be called right after the matching start_app. The
# <port> argument is accepted for call compatibility but the live port is always APP_PORT.
# Usage: wait_for_ready <port>
#
# Takes the caller's port variable name so it can write back the port the app actually ended up on.
# Fixes the intermittent failure where a relaunched app was addressed on its old port: on a timeout this relaunches the
# app, which binds a new OS-assigned port, and without the write-back the caller went on posting to
# the port of the instance that never became ready. The visible failure was
# "curl failed (exit N) posting to <command>", followed by a log-pattern timeout that looked
# unrelated.
wait_for_ready() {
    local max_attempts=2
    local attempt=1
    # The relaunch path below starts a new app instance on a new OS-assigned port, which start_app
    # writes to the APP_PORT global. A test that snapshotted APP_PORT into its own variable before
    # calling this (tests 7 and 8 must, because they run two instances) would otherwise keep driving
    # the instance that was just killed, and every later send_command posts to a dead port. Naming
    # that variable here lets the live port be written back into it.
    local port_var="${2:-APP_PORT}"
    log_info "Waiting for app to be ready on port $APP_PORT..."
    while [ "$attempt" -le "$max_attempts" ]; do
        local elapsed=0
        while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
            if curl -sf "http://localhost:$APP_PORT/ready" > /dev/null 2>&1; then
                printf -v "$port_var" '%s' "$APP_PORT"
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
            # Keep the failed launch's log. start_app redirects with ">", which truncates, so the
            # relaunch below wipes the only record of why the app never became ready. That left
            # "App failed to become ready" impossible to diagnose from a retained test directory:
            # every artifact held the log of the attempt that worked, not the one that did not.
            if [ -f "$APP_TMP_DIR/app.log" ]; then
                mv "$APP_TMP_DIR/app.log" "$APP_TMP_DIR/app-failed-attempt-$attempt.log"
                log_info "Kept the failed launch's log as app-failed-attempt-$attempt.log"
            fi
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
# Resets wait_for_log's cursor back to the start of app.log.
#
# start_app redirects the app's output to app.log with `>`, which truncates it, so a test that stops
# the app and starts it again gets a log that begins at line 1 while the cursor still points at
# wherever the previous run finished. Every wait after that would then look past the end of the file
# and time out on lines that are plainly there. Call this straight after restarting the app.
# Usage: reset_log_cursor <tmp_dir>
#
reset_log_cursor() {
    local tmp_dir="$1"
    echo "0" > "$tmp_dir/.log-cursor"
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
# Reads the current value of the element with the given data-id, echoing it to stdout (empty when the
# element is absent). Value-returning helper: it prints and never exits, so it is safe inside $(...)
# and safe to call after a failed assertion to report what the screen actually said.
# Usage: read_value <port> <data-id>
#
read_value() {
    local port="$1"
    local data_id="$2"
    local response
    response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
    # grep -o only prints matches, so on no match nothing is echoed.
    echo "$response" | grep -o '"value":"[^"]*"' | head -n1 | sed 's/^"value":"//; s/"$//'
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
    cleanup_apps "$tmp_dir"
}

#
# Starts the local MinIO S3 emulator in the given state directory and reads back what it bound.
#
# On return S3_EMULATOR_PORT, S3_EMULATOR_BUCKET, S3_EMULATOR_ACCESS_KEY and S3_EMULATOR_SECRET_KEY
# are exported (from the emulator's own env file), along with S3_ENDPOINT, the http:// URL the app
# reaches it at. The endpoint is addressed by IP, never "localhost": without path-style addressing
# the SDK puts the bucket into the hostname, which on a machine that resolves *.localhost reaches the
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
    export S3_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
    log_info "S3 emulator at $S3_ENDPOINT, bucket $S3_EMULATOR_BUCKET"
}

#
# Stops the S3 emulator recorded in the given state directory. Never fails, including when nothing
# was ever started, so it is safe in an unconditional trap.
# Usage: stop_s3_emulator <state-dir>
#
stop_s3_emulator() {
    local state_dir="$1"
    (cd "$SMOKE_REPO_ROOT" && bun run s3-emulator stop "$state_dir") >/dev/null 2>&1 || true
    return 0
}

#
# Adds an s3-credentials secret through the app's own Add Secret dialog, the way a user would, rather
# than writing the vault file directly. Every field is filled: a secret carrying only a region cannot
# reach a server, so the tests that actually connect need all five.
#
# The secrets page must already be showing, and the type defaults to s3-credentials so no type switch
# is needed. Expects TMP_DIR to be set, as wait_for_log takes it.
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
# Greps app.log for [ERROR] lines and fails if any are found. An optional second argument is an
# extended-regex of [ERROR] lines to ignore, for an error a test provokes on purpose (the S3 test
# deliberately browses with bad credentials and asserts the failure is surfaced); any remaining
# [ERROR] line still fails the check. Mirrors the mobile harness's check_no_errors.
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
        # Fatal by construction: signalling failure by return let a test print [FAIL], fall through to
        # log_success and exit 0 (a false pass). It is never called from a cleanup path or a command
        # substitution, so exit is safe and makes an error in app.log fail the test outright.
        exit 1
    fi
    log_success "No errors in app.log"
    return 0
}

#
# Merges one secret into the plaintext vault's single vault.json file, which holds every secret
# keyed by its name. The merge is a read-modify-write, so seeding a second secret keeps the first.
# An absent vault file starts from an empty object. A vault file that does not parse fails the test
# outright rather than being silently replaced with a fresh one.
#
# jq --argjson passes the secret in as data, so nothing is spliced into a template as text.
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
        # Called from the top level of a test script, not inside a subshell or a command
        # substitution, so exit is safe and makes a corrupt vault file fail the test outright.
        echo "Vault file $vault_file is not valid JSON" >&2
        exit 1
    fi
    printf '%s' "$merged" > "$vault_file"
    chmod 600 "$vault_file"
}

#
# Returns success when a vault directory's vault.json holds a secret under the given name.
# `has` is false when the key is absent, and jq -e exits non-zero on a false result.
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
# Seeds one secret into the plaintext vault, in the JSON envelope the vault stores a secret in
# (an object with name, type and value, where value is always a string). For an s3-credentials
# secret that string is itself JSON, so pass the already-encoded JSON document as the value.
#
# jq --arg passes every value in as data, never as text spliced into a template, so a name or
# value containing a quote, a backslash or a newline is escaped by jq rather than becoming syntax.
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
# The same, with the secret's value read verbatim from a file, newlines and all, which is how a
# multi-line PEM gets in. jq --rawfile keeps the file's exact bytes, including any trailing newline,
# which $(cat ...) would strip.
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
