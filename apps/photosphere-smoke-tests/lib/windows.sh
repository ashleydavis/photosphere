#!/usr/bin/env bash

# The Windows platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# Run it under Git Bash on Windows. The app opens a normal window on the desktop of the session, so no virtual display is needed. Each
# scenario points LOCALAPPDATA at its own directory, which is where WebView2 keeps its profile, so two scenarios never share one, and
# the settings, vault and logs are in the scenario's directory through the same PHOTOSPHERE_* variables the Linux library sets. Every
# path given to the app is in the form a native Windows program understands.

# The helpers a scenario calls as ${PLATFORM}_<name> are the Linux library's: they work on the scenario's own directory with the tools
# Git Bash has, and nothing in them is Linux's own. The Linux library is read first so that the photosphere_platform_* functions below
# replace its own.
source "$PHOTOSPHERE_SMOKE_DIR/lib/linux.sh"

WINDOWS_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"

# The file the app's process group is recorded in, per scenario.
WINDOWS_PGID_FILE_NAME="app.pgid"

# The file the Windows pid of the app's process is recorded in, per scenario.
WINDOWS_WINPID_FILE_NAME="app.winpid"

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
    rm -f "$port_file" "$test_dir/$WINDOWS_WINPID_FILE_NAME"

    # The app's log starts again with the app, so a remembered position in the old one means nothing.
    rm -f "$test_dir/background-log-cursor.txt"
    mkdir -p "$test_dir/data"
    # WebView2 refuses to create its controller while the browser process of an earlier run of the app on the same data still holds the
    # user data folder (ERROR_BUSY, HRESULT 0x800700AA), and that process can outlive an app that was stopped by half a minute or more. So the
    # app waits until the folder is free. The browser holds the folder's lockfile open with no sharing and deletes it when it closes it,
    # so the folder is free when the lockfile is gone or can be opened. Only this scenario's own folder is looked at: the WebView2
    # processes of other scenarios, other runs and other programs on the machine have nothing to do with it.
    local webview_lockfile="$test_dir/data/au.com.codecapers.photosphere/WebView2/EBWebView/lockfile"
    local webview_waited=0
    while [ -e "$webview_lockfile" ] && ! ( : >> "$webview_lockfile" ) 2>/dev/null; do
        if [ "$webview_waited" -ge 120 ]; then
            echo "The WebView2 user data folder of the last run was still in use 60 seconds after the app was stopped: $webview_lockfile" >&2
            return 1
        fi
        sleep 0.5
        webview_waited=$((webview_waited + 1))
    done
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    local pid pgid
    # The S3 variables a scenario exports for the CLI are removed, as the Linux library removes them: the app has to find credentials
    # the way it does on a phone, from the vault.
    read -r pid pgid < <(launch_in_process_group "$log" env \
        -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_ENDPOINT -u AWS_REGION -u AWS_SESSION_TOKEN \
        LOCALAPPDATA="$(windows_native_path "$test_dir/data")" \
        PHOTOSPHERE_TEST_MODE=1 \
        PHOTOSPHERE_CONFIG_DIR="$(windows_native_path "$test_dir/config")" \
        PHOTOSPHERE_CACHE_DIR="$(windows_native_path "$test_dir/cache")" \
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
    # Windows tools take the Windows pid, which is not the shell's pid of a native program. It is read once the app has written its port,
    # because until the shell has handed over to the program the shell's pid can still name the launcher, and it is checked to be the
    # app's.
    if ! cat "/proc/$pid/winpid" > "$test_dir/$WINDOWS_WINPID_FILE_NAME" || ! windows_app_process_running "$test_dir"; then
        echo "Could not find the Windows process of the app (shell pid $pid)." >&2
        return 1
    fi
    PHOTOSPHERE_CONTROL_HOST=127.0.0.1
    PHOTOSPHERE_CONTROL_PORT="$(tr -d '\n' < "$port_file")"
    export PHOTOSPHERE_CONTROL_HOST PHOTOSPHERE_CONTROL_PORT
}

#
# Succeeds when the app's Windows process, whose Windows pid was recorded when it was started, is still running.
# Usage: windows_app_process_running <test_dir>
#
windows_app_process_running() {
    local winpid_file="$1/$WINDOWS_WINPID_FILE_NAME"
    if [ ! -s "$winpid_file" ]; then
        return 1
    fi
    tasklist //fo csv //nh //fi "PID eq $(cat "$winpid_file")" //fi "IMAGENAME eq photosphere.exe" | grep -q '"photosphere.exe"'
}

#
# Stops the app and everything it started. Signalling the process group ends the shell's view of the app at once, but the Windows
# process goes on running for many seconds after it, and so do the WebView2 processes it started, which hold the scenario's user data
# folder. So the app's Windows process and its whole tree are ended by the Windows pid recorded when it was started, and the stop waits
# until that process is gone. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    if windows_app_process_running "$test_dir"; then
        local winpid
        winpid="$(cat "$test_dir/$WINDOWS_WINPID_FILE_NAME")"
        if ! taskkill //PID "$winpid" //T //F > /dev/null && windows_app_process_running "$test_dir"; then
            echo "Could not end the app's Windows process $winpid and its tree." >&2
            return 1
        fi
    fi
    if [ -f "$test_dir/$WINDOWS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" || true
    fi
    local waited=0
    while windows_app_process_running "$test_dir"; do
        if [ "$waited" -ge 60 ]; then
            echo "The app's Windows process $(cat "$test_dir/$WINDOWS_WINPID_FILE_NAME") was still running 30 seconds after it was ended." >&2
            return 1
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
}

#
# Waits for the app to end: its process group and its Windows process both. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    wait_for_process_group_exit "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" "$seconds" || return 1
    local deadline=$((SECONDS + seconds))
    while windows_app_process_running "$test_dir"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            return 1
        fi
        sleep 0.25
    done
}

#
# Succeeds when the app's process is running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    windows_app_process_running "$1"
}

#
# Clears what the app has stored. On a desktop every scenario's settings, vault, logs and web view data are in the scenario's own fresh
# directory, so there is nothing left by an earlier scenario to clear and this does nothing.
#
photosphere_platform_reset_app_state() {
    return 0
}

#
# The names scenarios call as ${PLATFORM}_<name>, each the Linux library's helper of the same name. Every one the Linux library defines
# is given a Windows name, so a helper added there is never missing here.
#
for linux_helper in $(declare -F | sed -n 's/^declare -f linux_//p'); do
    eval "windows_${linux_helper}() { linux_${linux_helper} \"\$@\"; }"
done
unset linux_helper
