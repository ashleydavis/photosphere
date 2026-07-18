#!/bin/bash

# Electron launcher for the shared smoke-test harness. Sourced by common.sh when
# PLATFORM=electron. Starts the desktop app in test mode pointed at the host control
# bridge (PHOTOSPHERE_TEST_PORT), with isolated config/vault/log dirs under the test
# tmp dir. Mirrors the env and launch flags used by the former apps/desktop/smoke-tests.

DESKTOP_DIR="$REPO_DIR/apps/desktop"
DESKTOP_FRONTEND_DIR="$REPO_DIR/apps/desktop-frontend"

#
# Resolves the electron binary path for the desktop package.
#
electron_resolve_binary() {
    ( cd "$DESKTOP_DIR" && node -e "process.stdout.write(require('electron'))" )
}

#
# No-op env setup (electron/xvfb are checked in prepare).
#
electron_setup_env() {
    return 0
}

#
# Verifies the electron binary and, on Linux, notes xvfb-run availability.
#
electron_prepare() {
    electron_setup_env
    if ! electron_resolve_binary >/dev/null 2>&1; then
        log_error "Electron binary not found. Run bun install from the repo root."
        return 1
    fi
    if [ "$(uname -s)" = "Linux" ] && [ "${SHOW_UI:-0}" != "1" ]; then
        if ! command -v xvfb-run >/dev/null 2>&1; then
            log_info "xvfb-run not installed; Electron will run with a visible UI. Install xvfb to run headless."
        fi
    fi
}

#
# Bundles the desktop frontend and main process (same as the former smoke-tests.sh).
#
electron_build() {
    log_info "Bundling desktop-frontend..."
    ( cd "$DESKTOP_FRONTEND_DIR" && bun run bundle ) || return 1
    log_info "Bundling desktop..."
    ( cd "$DESKTOP_DIR" && bun run bundle ) || return 1
}

#
# No install step for Electron (source/binary launch).
#
electron_install() {
    return 0
}

#
# Launches the Electron app in test mode against the host control bridge.
# Usage: electron_launch <bridge_port> [x_pos]
# Reads APP_TMP_DIR (set by start_app) for config/vault/log/pid paths.
#
electron_launch() {
    local port="$1"
    local x_pos="${2:-0}"
    local tmp_dir="${APP_TMP_DIR:?APP_TMP_DIR must be set by start_app before electron_launch}"

    mkdir -p "$tmp_dir/config" "$tmp_dir/vault" "$tmp_dir"

    local launch_args=()
    if [ "${USE_BINARY:-false}" = "true" ]; then
        # Packaged binary path detection (linux/mac/win) — same as former desktop common.sh.
        local platform
        case "$(uname -s)" in
            Linux*) platform=linux ;;
            Darwin*) platform=mac ;;
            MINGW*|MSYS*|CYGWIN*|Windows_NT) platform=win ;;
            *) platform=linux ;;
        esac
        case "$platform" in
            linux) launch_args+=("$DESKTOP_DIR/release/linux-unpacked/photosphere") ;;
            mac) launch_args+=("$DESKTOP_DIR/release/mac/Photosphere.app/Contents/MacOS/Photosphere") ;;
            win) launch_args+=("$DESKTOP_DIR/release/win-unpacked/photosphere.exe") ;;
        esac
    else
        local electron_bin
        electron_bin="$(electron_resolve_binary)"
        launch_args+=("$electron_bin" "$DESKTOP_DIR")
    fi

    local wrapper=()
    if [ "${SHOW_UI:-0}" != "1" ] && [ "$(uname -s)" = "Linux" ]; then
        if command -v xvfb-run >/dev/null 2>&1; then
            wrapper=(xvfb-run -a)
            log_info "Running headless (xvfb-run). Set SHOW_UI=1 to show the window."
        fi
    fi

    # Stdout/stderr become app.log so FileLogger console output (and main-process logs) are
    # visible to wait_for_log. The bridge also appends renderer console lines to the same file.
    PHOTOSPHERE_TEST_MODE=1 \
    PHOTOSPHERE_TEST_PORT="$port" \
    PHOTOSPHERE_CONFIG_DIR="$tmp_dir/config" \
    PHOTOSPHERE_VAULT_DIR="$tmp_dir/vault" \
    PHOTOSPHERE_VAULT_TYPE=plaintext \
    PHOTOSPHERE_LOG_DIR="$tmp_dir" \
    PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
    PHOTOSPHERE_TEST_PICK_FILE_PATH="${PHOTOSPHERE_TEST_PICK_FILE_PATH:-}" \
    PHOTOSPHERE_TEST_DOWNLOAD_FOLDER="${PHOTOSPHERE_TEST_DOWNLOAD_FOLDER:-}" \
    TEST_TMP_DIR="$tmp_dir" \
    NODE_ENV=testing \
    "${wrapper[@]}" "${launch_args[@]}" --no-sandbox --disable-gpu \
        -geometry "${PHOTOSPHERE_TEST_GEOMETRY:-960x800+${x_pos}+0}" \
        > "$tmp_dir/app.log" 2>&1 &
    echo $! > "$tmp_dir/app.pid"
    log_info "Electron app started (PID $(cat "$tmp_dir/app.pid"), bridge port $port, x=$x_pos)"
}

#
# Stops the Electron app recorded in APP_TMP_DIR/app.pid (or discovers pids under the tmp tree).
# Usage: electron_stop <port>
#
electron_stop() {
    local tmp_dir="${APP_TMP_DIR:-}"
    if [ -z "$tmp_dir" ]; then
        return 0
    fi
    local pid_file="$tmp_dir/app.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
}

#
# Seeds a fixture database onto the host filesystem for Electron (copy into tmp or use path as-is).
# For Electron, "seeding" means making the fixture available at a host path the app can open.
# Usage: electron_seed_database <host_fixture_dir> <dest_name>
#
electron_seed_database() {
    local host_fixture_dir="$1"
    local dest_name="$2"
    local tmp_dir="${APP_TMP_DIR:?APP_TMP_DIR must be set}"
    local dest_path="$tmp_dir/$dest_name"
    rm -rf "$dest_path"
    cp -a "$host_fixture_dir" "$dest_path"
    log_info "Seeded database fixture to $dest_path"
    # Publish the path for tests that need the absolute host path.
    ELECTRON_SEEDED_DB_PATH="$dest_path"
}

#
# Resets a relative path under the Electron tmp dir (best-effort remove).
# Usage: electron_reset_path <relative_path>
#
electron_reset_path() {
    local relative_path="$1"
    local tmp_dir="${APP_TMP_DIR:?APP_TMP_DIR must be set}"
    rm -rf "$tmp_dir/$relative_path"
}

#
# No device storage to clear after Electron runs.
#
electron_cleanup() {
    return 0
}
