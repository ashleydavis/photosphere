#!/usr/bin/env bash

# The MacOS platform library of the Ziggy example's smoke tests. See common.sh for what it implements.
#
# The app is the built ZiggyExample.app's executable, started directly so its process group is known. Each scenario gets a
# home directory of its own (HOME and CFFIXED_USER_HOME), so the app's Application Support directory is isolated. The app
# opens a real window, so the run needs a logged-in graphical session.

MACOS_SCRIPTS_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example/scripts"

# The file the app's process group is recorded in, per scenario.
MACOS_PGID_FILE_NAME="app.pgid"

ziggy_platform_prepare() {
    local run_dir="$1"
    bash "$MACOS_SCRIPTS_DIR/build-macos.sh" --test-hooks --configuration Release --native-dir "$run_dir/test-native" --build-dir "$run_dir/test-build" || return 1
    bash "$MACOS_SCRIPTS_DIR/build-macos.sh" --configuration Release --native-dir "$run_dir/release-native" --build-dir "$run_dir/release-build" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local app="$ZIGGY_SMOKE_RUN_DIR/$kind-build/Build/Products/Release/ZiggyExample.app/Contents/MacOS/ZiggyExample"
    local log="$test_dir/app.log"
    local port_file="$test_dir/control-port.txt"
    mkdir -p "$test_dir/home"
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env \
        HOME="$test_dir/home" \
        CFFIXED_USER_HOME="$test_dir/home" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$port_file" \
        "$app") || return 1
    echo "$pgid" > "$test_dir/$MACOS_PGID_FILE_NAME"
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
    if [ -f "$test_dir/$MACOS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")" || true
    fi
}

ziggy_platform_data_dir() {
    printf '%s\n' "$1/home/Library/Application Support/dev.ziggy.example"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pgid
    pgid="$(cat "$test_dir/$MACOS_PGID_FILE_NAME")"
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
    process_group_alive "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")"
}

# The Zig static library carries the core, so it is what scenario 8 searches. The app's executable is not searched,
# because the linker may drop code the app never reaches.
ziggy_platform_artifact_files() {
    local kind="$1"
    printf '%s\n' "$ZIGGY_SMOKE_RUN_DIR/$kind-native/lib/libziggy_example.a"
}

ziggy_platform_has_control_port() {
    [ -s "$1/control-port.txt" ]
}

#
# Succeeds when the developer tools are showing. The web inspector docks inside the window, so the page's area is smaller than it
# was. Usage: ziggy_platform_devtools_visible <test_dir> <the page's area before they opened>
#
ziggy_platform_devtools_visible() {
    [ "$(viewport_size)" != "$2" ]
}
