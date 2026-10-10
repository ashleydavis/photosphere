#!/usr/bin/env bash

# The Linux platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# The app runs on a virtual display of its own, so a run shows no window and two runs never share a display. WebKitGTK starts its web
# process in a bubblewrap sandbox, which some Linux setups do not allow an unprivileged program to create (Ubuntu's default restriction
# on user namespaces is one). The sandbox is switched off for these test processes only, through the environment WebKitGTK documents for
# it. SHOW_UI=1 shows the window instead, for watching a failing scenario.

# The file the app's process group is recorded in, per scenario.
LINUX_PGID_FILE_NAME="app.pgid"

photosphere_platform_prepare() {
    local run_dir="$1"
    (cd "$PHOTOSPHERE_SMOKE_REPO_ROOT" && bun run --filter=ziggy bundle:ui) || return 1
    # The page is embedded in the executable, so nothing but the executable is installed. A scenario that passes proves the page loads
    # from the executable alone, which is why nothing is copied beside it.
    (cd "$PHOTOSPHERE_SMOKE_REPO_ROOT" && zig build photosphere-linux -Dtest-hooks=true -p "$run_dir/test") || return 1
    local installed
    installed="$(find "$run_dir/test/bin" -type f | wc -l)"
    if [ "$installed" -ne 1 ]; then
        echo "The Linux build installed more than the one executable:" >&2
        find "$run_dir/test/bin" -type f >&2
        return 1
    fi
}

#
# Starts the app for one scenario, recording what it started through launch_in_process_group. Sets PHOTOSPHERE_CONTROL_HOST and
# PHOTOSPHERE_CONTROL_PORT to where the test control connection can be reached. The scenario's settings, vault, logs and web view data
# are all inside the scenario's own directory, and so is the home directory, so nothing reaches the settings of the person running the
# test. Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/test/bin/photosphere"
    local port_file="$test_dir/control-port.txt"
    rm -f "$port_file"
    mkdir -p "$test_dir/data" "$test_dir/home"
    local wrapper=()
    if [ "${SHOW_UI:-0}" != "1" ]; then
        wrapper=(xvfb-run -a -s "-screen 0 1280x1024x24")
    fi
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$test_dir/app.log" env \
        WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
        HOME="$test_dir/home" \
        XDG_DATA_HOME="$test_dir/data" \
        PHOTOSPHERE_TEST_MODE=1 \
        PHOTOSPHERE_CONFIG_DIR="$test_dir/config" \
        PHOTOSPHERE_VAULT_DIR="$test_dir/vault" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        PHOTOSPHERE_LOG_DIR="$test_dir" \
        PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        TEST_TMP_DIR="$test_dir" \
        ZIGGY_TEST_MODE=1 \
        ZIGGY_TEST_PORT_FILE="$port_file" \
        "${wrapper[@]}" "$app") || return 1
    echo "$pid" > "$test_dir/app.pid"
    echo "$pgid" > "$test_dir/$LINUX_PGID_FILE_NAME"
    local waited=0
    while [ ! -s "$port_file" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "The app exited before its control connection came up. Its log:" >&2
            cat "$test_dir/app.log" >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never wrote its control port." >&2
            cat "$test_dir/app.log" >&2
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
    if [ -f "$test_dir/$LINUX_PGID_FILE_NAME" ]; then
        kill_process_group "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")" || true
    fi
}

#
# Waits for the app's process group to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    wait_for_process_group_exit "$(cat "$test_dir/$LINUX_PGID_FILE_NAME")" "$seconds"
}

#
# Succeeds when the app's process is running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    process_group_alive "$(cat "$1/$LINUX_PGID_FILE_NAME")"
}

#
# Clears what the app has stored. On a desktop every scenario's settings, vault, logs, home directory and web view data are in the
# scenario's own fresh directory, so there is nothing left by an earlier scenario to clear and this does nothing.
#
photosphere_platform_reset_app_state() {
    return 0
}
