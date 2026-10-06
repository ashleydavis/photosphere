#!/usr/bin/env bash

# The Windows platform library of the Ziggy example's smoke tests. See common.sh for what it implements.
#
# Run it under Git Bash on Windows. The app opens a normal window on the desktop of the session, so no virtual display is
# needed. Each scenario points LOCALAPPDATA at its own directory, which is where the app keeps its data and WebView2 keeps
# its profile, so two scenarios never share either.

WINDOWS_SCRIPTS_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example/scripts"

# The file the app's process group is recorded in, per scenario.
WINDOWS_PGID_FILE_NAME="app.pgid"

#
# Prints a path in the form a native Windows program understands (D:/a/...), and the path unchanged where there is no
# cygpath (a cross check from Linux).
#
windows_native_path() {
    if command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

ziggy_platform_prepare() {
    local run_dir
    run_dir="$(windows_native_path "$1")"
    bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --test-hooks --prefix "$run_dir/test" || return 1
    bash "$WINDOWS_SCRIPTS_DIR/sync-windows.sh" --prefix "$run_dir/release" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local app="$ZIGGY_SMOKE_RUN_DIR/$kind/ziggy-example/ziggy-example.exe"
    local log="$test_dir/app.log"
    local port_file="$test_dir/control-port.txt"
    rm -f "$port_file"
    mkdir -p "$test_dir/data"
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env \
        LOCALAPPDATA="$(windows_native_path "$test_dir/data")" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$(windows_native_path "$port_file")" \
        "$app") || return 1
    echo "$pgid" > "$test_dir/$WINDOWS_PGID_FILE_NAME"
    if [ "$kind" = "release" ]; then
        return 0
    fi
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
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="$(tr -d '\n' < "$port_file")"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$WINDOWS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data/dev.ziggy.example"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")"
    local waited=0
    while process_group_alive "$pgid"; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_is_running() {
    local test_dir="$1"
    process_group_alive "$(cat "$test_dir/$WINDOWS_PGID_FILE_NAME")"
}

ziggy_platform_artifact_files() {
    local kind="$1"
    printf '%s\n' "$ZIGGY_SMOKE_RUN_DIR/$kind/ziggy-example/ziggy-example.exe"
}

ziggy_platform_has_control_port() {
    [ -s "$1/control-port.txt" ]
}

#
# Succeeds when the developer tools are showing. WebView2 opens them as a window of their own, so the page's area does not change and
# they are found by their window's title, "DevTools - " and the page's address. The address holds this run's build directory, so the
# developer tools of any other app or run on the machine do not count. Only the WebView2 processes are asked, because asking every
# process for its window title takes many seconds.
# Usage: ziggy_platform_devtools_visible <test_dir> <the page's area before they opened>
#
ziggy_platform_devtools_visible() {
    local windows
    windows="$(tasklist //v //fo csv //nh //fi "IMAGENAME eq msedgewebview2.exe")" || fail "could not list the WebView2 windows"
    printf '%s\n' "$windows" | grep -qF "DevTools - file:///$(windows_native_path "$ZIGGY_SMOKE_RUN_DIR")/"
}

ziggy_platform_leave_app() {
    choose_menu_item close-window
}

ziggy_platform_process_alive() {
    ziggy_platform_is_running "$1"
}
