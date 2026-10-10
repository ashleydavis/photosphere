#!/usr/bin/env bash

# The MacOS platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# The app is the built Photosphere.app's executable, started directly so its process group is known. Each scenario gets a home directory
# of its own (HOME and CFFIXED_USER_HOME), so the web view's data and the app's Application Support directory are isolated, and the
# settings, vault and logs are in the scenario's directory through the same PHOTOSPHERE_* variables the Linux library sets. The app
# opens a real window, so the run needs a logged-in graphical session.

MACOS_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"

# The file the app's process group is recorded in, per scenario.
MACOS_PGID_FILE_NAME="app.pgid"

photosphere_platform_prepare() {
    local run_dir="$1"
    bash "$MACOS_SCRIPTS_DIR/build-macos.sh" --test-hooks --configuration Release --native-dir "$run_dir/test-native" --build-dir "$run_dir/test-build" || return 1
}

#
# Starts the app for one scenario, recording what it started through launch_in_process_group. Sets PHOTOSPHERE_CONTROL_HOST and
# PHOTOSPHERE_CONTROL_PORT to where the test control connection can be reached. Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/test-build/Build/Products/Release/Photosphere.app/Contents/MacOS/Photosphere"
    local log="$test_dir/app.log"
    local port_file="$test_dir/control-port.txt"
    rm -f "$port_file"
    mkdir -p "$test_dir/home"
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$log" env \
        HOME="$test_dir/home" \
        CFFIXED_USER_HOME="$test_dir/home" \
        PHOTOSPHERE_TEST_MODE=1 \
        PHOTOSPHERE_CONFIG_DIR="$test_dir/config" \
        PHOTOSPHERE_VAULT_DIR="$test_dir/vault" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        PHOTOSPHERE_LOG_DIR="$test_dir" \
        PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        TEST_TMP_DIR="$test_dir" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$port_file" \
        "$app") || return 1
    echo "$pid" > "$test_dir/app.pid"
    echo "$pgid" > "$test_dir/$MACOS_PGID_FILE_NAME"
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
    if [ -f "$test_dir/$MACOS_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")" || true
    fi
}

#
# Waits for the app's process group to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    wait_for_process_group_exit "$(cat "$test_dir/$MACOS_PGID_FILE_NAME")" "$seconds"
}

#
# Succeeds when the app's process is running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    process_group_alive "$(cat "$1/$MACOS_PGID_FILE_NAME")"
}

#
# Clears what the app has stored. On a desktop every scenario's settings, vault, logs, home directory and web view data are in the
# scenario's own fresh directory, so there is nothing left by an earlier scenario to clear and this does nothing.
#
photosphere_platform_reset_app_state() {
    return 0
}
