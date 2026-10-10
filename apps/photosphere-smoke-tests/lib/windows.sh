#!/usr/bin/env bash

# The Windows platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# Run it under Git Bash on Windows. The app opens a normal window on the desktop of the session, so no virtual display is needed. Each
# scenario points LOCALAPPDATA at its own directory, which is where WebView2 keeps its profile, so two scenarios never share one, and
# the settings, vault and logs are in the scenario's directory through the same PHOTOSPHERE_* variables the Linux library sets. Every
# path given to the app is in the form a native Windows program understands.

WINDOWS_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"

# The file the app's process group is recorded in, per scenario.
WINDOWS_PGID_FILE_NAME="app.pgid"

#
# Prints a path in the form a native Windows program understands (D:/a/...), and the path unchanged where there is no cygpath (a cross
# check from Linux).
#
windows_native_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

photosphere_platform_prepare() {
    local run_dir
    run_dir="$(windows_native_path "$1")"
    bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --test-hooks --prefix "$run_dir/test" || return 1
}

#
# Starts the app for one scenario, recording what it started through launch_in_process_group. Sets PHOTOSPHERE_CONTROL_HOST and
# PHOTOSPHERE_CONTROL_PORT to where the test control connection can be reached. Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/test/photosphere/photosphere.exe"
    local log="$test_dir/app.log"
    local port_file="$test_dir/control-port.txt"
    rm -f "$port_file"
    mkdir -p "$test_dir/data"
    if [ "${2:-}" = "keep-data" ]; then
        # The app is starting again on the same data. WebView2 refuses to create its controller while the first run's browser process
        # still holds the user data folder (ERROR_BUSY, HRESULT 0x800700AA), so the restart waits until no WebView2 process is left.
        local webview_waited=0
        while tasklist //fo csv //nh //fi "IMAGENAME eq msedgewebview2.exe" | grep -q "msedgewebview2.exe"; do
            if [ "$webview_waited" -ge 120 ]; then
                echo "A WebView2 process was still running 60 seconds after the app was stopped." >&2
                return 1
            fi
            sleep 0.5
            webview_waited=$((webview_waited + 1))
        done
    fi
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env \
        LOCALAPPDATA="$(windows_native_path "$test_dir/data")" \
        PHOTOSPHERE_TEST_MODE=1 \
        PHOTOSPHERE_CONFIG_DIR="$(windows_native_path "$test_dir/config")" \
        PHOTOSPHERE_VAULT_DIR="$(windows_native_path "$test_dir/vault")" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        PHOTOSPHERE_LOG_DIR="$(windows_native_path "$test_dir")" \
        PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        TEST_TMP_DIR="$(windows_native_path "$test_dir")" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$(windows_native_path "$port_file")" \
        "$app") || return 1
    echo "$pid" > "$test_dir/app.pid"
    echo "$pgid" > "$test_dir/$WINDOWS_PGID_FILE_NAME"
    local waited=0
    while [ ! -s "$port_file" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "The app exited before its control connection came up. Its log:" >&2
            cat "$log" >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never wrote its control port." >&2
            cat "$log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    PHOTOSPHERE_CONTROL_HOST=127.0.0.1
    PHOTOSPHERE_CONTROL_PORT="$(tr -d '\n' < "$port_file")"
    export PHOTOSPHERE_CONTROL_HOST PHOTOSPHERE_CONTROL_PORT
}

#
# Stops the app and everything it started. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$WINDOWS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" || true
    fi
}

#
# Waits for the app's process group to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    wait_for_process_group_exit "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" "$seconds"
}

#
# Succeeds when the app's process is running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    process_group_alive "$(cat "$1/$WINDOWS_PGID_FILE_NAME")"
}

#
# Clears what the app has stored. On a desktop every scenario's settings, vault, logs and web view data are in the scenario's own fresh
# directory, so there is nothing left by an earlier scenario to clear and this does nothing.
#
photosphere_platform_reset_app_state() {
    return 0
}
