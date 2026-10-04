#!/usr/bin/env bash

# The Linux platform library of the Ziggy example's smoke tests. See common.sh for what it implements.
#
# The app runs on a virtual display of its own, so a run shows no window and two runs never share a display.
# WebKitGTK starts its web process in a bubblewrap sandbox, which some Linux setups do not allow an unprivileged
# program to create (Ubuntu's default restriction on user namespaces is one). The sandbox is switched off for these test
# processes only, through the environment WebKitGTK documents for it.

LINUX_SHELL_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example/shells/linux"
LINUX_EXAMPLE_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example"

# The file the app's process group is recorded in, per scenario.
LINUX_PGID_FILE_NAME="app.pgid"

ziggy_platform_prepare() {
    local run_dir="$1"
    (cd "$LINUX_EXAMPLE_DIR" && bun run bundle:ui) || return 1
    (cd "$LINUX_SHELL_DIR" && zig build -Dtest-hooks=true -p "$run_dir/test") || return 1
    (cd "$LINUX_SHELL_DIR" && zig build -p "$run_dir/release") || return 1
    mkdir -p "$run_dir/test/bin/ui" "$run_dir/release/bin/ui"
    cp -R "$LINUX_EXAMPLE_DIR/dist/." "$run_dir/test/bin/ui/" || return 1
    cp -R "$LINUX_EXAMPLE_DIR/dist/." "$run_dir/release/bin/ui/" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local app="$ZIGGY_SMOKE_RUN_DIR/$kind/bin/ziggy-example"
    local log="$test_dir/app.log"
    local port_file="$test_dir/control-port.txt"
    mkdir -p "$test_dir/data"
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env \
        WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
        XDG_DATA_HOME="$test_dir/data" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$port_file" \
        xvfb-run -a -s "-screen 0 1280x1024x24" "$app") || return 1
    echo "$pgid" > "$test_dir/$LINUX_PGID_FILE_NAME"
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
    if [ -f "$test_dir/$LINUX_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/data/dev.ziggy.example"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$LINUX_PGID_FILE_NAME")"
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
    process_group_alive "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")"
}

ziggy_platform_artifact_files() {
    local kind="$1"
    printf '%s\n' "$ZIGGY_SMOKE_RUN_DIR/$kind/bin/ziggy-example"
}

ziggy_platform_has_control_port() {
    [ -s "$1/control-port.txt" ]
}


#
# Succeeds when the developer tools are showing. They dock inside the window, so the page's area is smaller than it was.
# Usage: ziggy_platform_devtools_visible <test_dir> <the page's area before they opened>
#
ziggy_platform_devtools_visible() {
    [ "$(viewport_size)" != "$2" ]
}
