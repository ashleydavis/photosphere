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
    local build="${PHOTOSPHERE_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        (cd "$PHOTOSPHERE_SMOKE_REPO_ROOT" && bun run --filter=ziggy build:linux -- --prefix "$build") || return 1
    fi
    if [ ! -f "$build/bin/photosphere" ]; then
        echo "The Linux build $build has no bin/photosphere." >&2
        return 1
    fi
    # The page is embedded in the executable, so the build installs nothing but the executable. A scenario that passes proves the page
    # loads from the executable alone.
    local installed
    installed="$(find "$build/bin" -type f | wc -l)"
    if [ "$installed" -ne 1 ]; then
        echo "The Linux build installs more than the one executable:" >&2
        find "$build/bin" -type f >&2
        return 1
    fi
    mkdir -p "$run_dir/app/photosphere"
    cp "$build/bin/photosphere" "$run_dir/app/photosphere/" || return 1
}

#
# Starts the app for one scenario, recording what it started through launch_in_process_group, with --remote-control and the
# address of the scenario's remote control server, which it starts first. The scenario's settings, vault, logs and web view data
# are all inside the scenario's own directory, and so is the home directory, so nothing reaches the settings of the person running the
# test. Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/app/photosphere/photosphere"

    # The app's log starts again with the app, so a remembered position in the old one means nothing.
    rm -f "$test_dir/background-log-cursor.txt"
    mkdir -p "$test_dir/data" "$test_dir/home"
    local wrapper=()
    if [ "${SHOW_UI:-0}" != "1" ]; then
        wrapper=(xvfb-run -a -s "-screen 0 1280x1024x24")
    fi
    photosphere_start_remote_control_server "$test_dir" || return 1
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    local pid pgid
    # The S3 variables a scenario exports for the CLI are removed: a phone never sees its host's environment, so the app has to find
    # credentials the way it does there, from the vault.
    read -r pid pgid < <(launch_in_process_group "$test_dir/app.log" env \
        -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_ENDPOINT -u AWS_REGION -u AWS_SESSION_TOKEN \
        WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
        HOME="$test_dir/home" \
        XDG_DATA_HOME="$test_dir/data" \
        PHOTOSPHERE_TEST_MODE=1 \
        PHOTOSPHERE_CONFIG_DIR="$test_dir/config" \
        PHOTOSPHERE_CACHE_DIR="$test_dir/cache" \
        PHOTOSPHERE_VAULT_DIR="$test_dir/vault" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        PHOTOSPHERE_LOG_DIR="$test_dir" \
        PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        TEST_TMP_DIR="$test_dir" \
        "${wrapper[@]}" "$app" --remote-control "$PHOTOSPHERE_REMOTE_CONTROL") || return 1
    echo "$pid" > "$test_dir/app.pid"
    echo "$pgid" > "$test_dir/$LINUX_PGID_FILE_NAME"
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

#
# The name scenarios call to clear the app's stored data, which is ${PLATFORM}_reset_app_state.
#
linux_reset_app_state() {
    photosphere_platform_reset_app_state
}

#
# Prints the absolute path of a name inside the scenario's files directory, which is where linux_seed_database puts a fixture.
# Usage: linux_app_path <relative_path_under_files>
#
linux_app_path() {
    echo "$TMP_DIR/files/$1"
}

#
# Copies a database fixture from the host into the scenario's files directory, the place linux_app_path names. A copy already there is
# replaced. Usage: linux_seed_database <host_fixture_dir> <relative_dest_under_files>
#
linux_seed_database() {
    local host_src="$1"
    local rel_dest="$2"
    local dest
    dest="$(linux_app_path "$rel_dest")"
    rm -rf "$dest" || return 1
    mkdir -p "$(dirname "$dest")" || return 1
    cp -r "$host_src" "$dest" || return 1
    echo "Seeded database fixture '$(basename "$host_src")' into $dest" >&2
}

#
# Writes the app's databases.toml into its settings directory, from outside the app and before it starts. The first two arguments are
# JSON: the databases as an array of {name, path} (description, origin, s3Key, encryptionKey and geocodingKey optional), and the recents
# as an array of names, empty when omitted. The third is the path of the database the app reopens on launch; omitted, no such key is
# written. Usage: linux_seed_databases_config '<databases json>' ['<recent names json>'] ['<last database path>']
#
linux_seed_databases_config() {
    local databases_json="$1"
    local recent_json="${2:-[]}"
    local last_database="${3:-}"
    mkdir -p "$TMP_DIR/config" || return 1
    if ! jq -rn --argjson databases "$databases_json" --argjson recent "$recent_json" --arg last "$last_database" '
        "recent_database_names = \($recent | tojson)",
        (if $last != "" then "last_database = \($last | tojson)" else empty end),
        ($databases[] |
            "",
            "[[databases]]",
            "name = \(.name | tojson)",
            "description = \((.description // "") | tojson)",
            "path = \(.path | tojson)",
            (if .origin then "origin = \(.origin | tojson)" else empty end),
            (if .s3Key then "s3_key = \(.s3Key | tojson)" else empty end),
            (if .encryptionKey then "encryption_key = \(.encryptionKey | tojson)" else empty end),
            (if .geocodingKey then "geocoding_key = \(.geocodingKey | tojson)" else empty end))
    ' > "$TMP_DIR/config/databases.toml"; then
        echo "Could not render the app's database list from: $databases_json" >&2
        return 1
    fi
}

#
# Writes the syncing settings into the sync section of the app's config.yaml, keeping every other section the file already has. The pause
# is left out, so the app's default applies, when none is given.
# Usage: linux_seed_sync_config <enabled true|false> <only_on_wifi true|false> [pause_ms] [database_path]
#
linux_seed_sync_config() {
    local enabled="$1"
    local only_on_wifi="$2"
    local pause_ms="${3:-}"
    local database_path="${4:-}"
    local value
    for value in "$enabled" "$only_on_wifi"; do
        if [ "$value" != "true" ] && [ "$value" != "false" ]; then
            echo "linux_seed_sync_config takes true or false for enabled and only_on_wifi, got: $value" >&2
            return 1
        fi
    done
    if [ -n "$pause_ms" ] && ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "linux_seed_sync_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    mkdir -p "$TMP_DIR/config" || return 1
    local rendered
    rendered="$(mktemp)"
    if [ -f "$TMP_DIR/config/config.yaml" ]; then
        sed -e '/^sync:/,/^[^[:space:]]/{/^sync:/d;/^[[:space:]]/d}' "$TMP_DIR/config/config.yaml" > "$rendered"
    fi
    {
        echo "sync:"
        echo "  enabled: $enabled"
        echo "  only_on_wifi: $only_on_wifi"
        if [ -n "$pause_ms" ]; then
            echo "  pause_between_runs_ms: $pause_ms"
        fi
        if [ -n "$database_path" ]; then
            echo "  database_path: $(jq -n --arg path "$database_path" '$path')"
        fi
    } >> "$rendered"
    mv "$rendered" "$TMP_DIR/config/config.yaml"
}

#
# A desktop asks for no notification permission, so there is nothing to grant. Usage: linux_grant_notification_permission
#
linux_grant_notification_permission() {
    return 0
}

#
# Removes a path under the scenario's files directory so a scenario that creates fresh state there can be run again. Removes the one
# named path only. Usage: linux_reset_path <relative_path_under_files>
#
linux_reset_path() {
    local target
    target="$(linux_app_path "$1")"
    if [ -d "$target" ] && [ ! -L "$target" ]; then
        find "$target" -mindepth 1 -delete || return 1
        rmdir "$target" || return 1
    else
        rm -f "$target" || return 1
    fi
}

#
# Waits until the given path under the scenario's files directory exists and is non-empty, to see a background task's effect on storage.
# Returns 0 once it is there, non-zero after DEFAULT_WAIT_TIMEOUT seconds. Usage: linux_wait_for_file <relative_path_under_files>
#
linux_wait_for_file() {
    local target
    target="$(linux_app_path "$1")"
    local deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -e "$target" ] && { [ ! -d "$target" ] || [ -n "$(ls -A "$target")" ]; }; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    return 1
}

#
# Succeeds when a path under the scenario's files directory exists. Usage: linux_path_exists <relative_path_under_files>
#
linux_path_exists() {
    [ -e "$(linux_app_path "$1")" ]
}

#
# Makes the next download end as the user cancelling it. A desktop shows a save dialog, so the dialog's answer is staged as no path at
# all, which is how a cancelled dialog answers. Usage: linux_cancel_next_download <port>
#
linux_cancel_next_download() {
    send_command "$1" pick-answer '{"paths":[]}'
}

#
# A desktop asks for no photo permission, so there is nothing to grant. Usage: linux_grant_media_permission
#
linux_grant_media_permission() {
    return 0
}

#
# The photo library helpers below are the names a scenario calls to give the app photos to take in, so one scenario body runs on every
# platform. A "library" is the folder a scenario puts its photos in and points automatic import at. On a desktop that is a folder
# inside the scenario's own directory, which automatic import watches as it would any folder the user chose.
#

#
# Prints where this run's photo library is. Usage: linux_library_dir <name_prefix>
#
linux_library_dir() {
    echo "$TMP_DIR/photo-libraries/$1"
}

#
# A desktop's library is inside the scenario's own fresh directory, so an earlier run cannot have left a photo in it and there is
# nothing to clear. Usage: linux_library_sweep <name_prefix>
#
linux_library_sweep() {
    return 0
}

#
# Puts a photo into the library, made when it is the first. The copy is dated now, which is the moment the photo entered the library.
# Usage: linux_library_add <library> <host_file> <name>
#
linux_library_add() {
    mkdir -p "$1" || return 1
    cp "$2" "$1/$3"
}

#
# Takes the named photos out of the library, and the library itself once it is empty. Usage: linux_library_remove <library> [name ...]
#
linux_library_remove() {
    local library="$1"
    shift
    local photo_name
    for photo_name in "$@"; do
        rm -f "$library/$photo_name"
    done
    rmdir "$library" 2>/dev/null || true
}

#
# Writes the automatic import settings into the auto_import section of the app's config.yaml, keeping every other section the file
# already has, so the import watches the library and nothing else. The last argument names a photo the library holds on a phone, where
# the device must know an album before it can be watched, and is not needed here.
# Usage: linux_seed_library_auto_import_config <enabled true|false> <default_database_path or ""> <pause_ms> <library> <photo_name_in_it>
#
linux_seed_library_auto_import_config() {
    local enabled="$1"
    local default_database_path="$2"
    local pause_ms="$3"
    local library="$4"
    if [ "$enabled" != "true" ] && [ "$enabled" != "false" ]; then
        echo "linux_seed_library_auto_import_config takes true or false for enabled, got: $enabled" >&2
        return 1
    fi
    if ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "linux_seed_library_auto_import_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    mkdir -p "$TMP_DIR/config" "$library" || return 1
    local rendered
    rendered="$(mktemp)"
    if [ -f "$TMP_DIR/config/config.yaml" ]; then
        sed -e '/^auto_import:/,/^[^[:space:]]/{/^auto_import:/d;/^[[:space:]]/d}' "$TMP_DIR/config/config.yaml" > "$rendered"
    fi
    {
        echo "auto_import:"
        echo "  enabled: $enabled"
        echo "  pause_between_runs_ms: $pause_ms"
        echo "  sources:"
        echo "    - type: folder"
        echo "      path: $(jq -n --arg path "$library" '$path')"
        echo "      recurse: true"
        if [ -n "$default_database_path" ]; then
            echo "  default_database_path: $(jq -n --arg path "$default_database_path" '$path')"
        fi
    } >> "$rendered"
    mv "$rendered" "$TMP_DIR/config/config.yaml"
}

#
# Prints how many originals the database in the directory of the given name holds, or 0 when there is none yet. The database is found by
# name under the scenario's directory, because the app makes its own default database inside the data directory it chose.
# Usage: linux_asset_count <database_dir_name>
#
linux_asset_count() {
    local database_dir
    database_dir="$(linux_app_database_dir "$1")"
    if [ -z "$database_dir" ] || [ ! -d "$database_dir/asset" ]; then
        echo 0
        return 0
    fi
    find "$database_dir/asset" -type f | wc -l | tr -d ' '
}

#
# Copies the database in the directory of the given name onto the given host directory, the way a phone's is copied off the device.
# Usage: linux_pull_database <dir_name> <local_dir>
#
linux_pull_database() {
    local database_dir
    database_dir="$(linux_app_database_dir "$1")"
    if [ -z "$database_dir" ]; then
        echo "There is no database directory named $1 under $TMP_DIR to copy" >&2
        return 1
    fi
    mkdir -p "$2" || return 1
    cp -r "$database_dir" "$2/"
}

#
# The log line that says automatic import was started, as this platform's app writes it. Usage: linux_auto_import_started_log
#
linux_auto_import_started_log() {
    echo "Starting automatic import into"
}

#
# Succeeds when the app's process is still alive. Usage: linux_app_process_alive
#
linux_app_process_alive() {
    photosphere_platform_is_running "$TMP_DIR"
}

#
# A desktop has no device to claim. Usage: linux_claim_device
#
linux_claim_device() {
    return 0
}

#
# A desktop is never a real phone. Usage: linux_is_real_device
#
linux_is_real_device() {
    return 1
}

#
# A desktop has no lock screen that stops its work. Usage: linux_require_unlocked
#
linux_require_unlocked() {
    return 0
}

#
# The scenario's directory is fresh, so a desktop's data may always be wiped. Usage: linux_may_wipe_app_data
#
linux_may_wipe_app_data() {
    return 0
}

#
# A desktop's app has no screen that goes off or back on, and no state that a Home key puts it in: the core runs automatic import and
# syncing for as long as the process lives, whether or not the window is showing. These say so rather than pretending: the window is
# left as it is, which is the state a desktop's work always runs in. Usage: linux_send_app_to_background, linux_bring_app_to_front,
# linux_screen_on
#
linux_send_app_to_background() {
    echo "A desktop has no background state: the core runs its work whether or not the window is showing." >&2
}

linux_bring_app_to_front() {
    echo "A desktop's window was never taken off screen, so there is nothing to bring back." >&2
}

linux_screen_on() {
    return 0
}

#
# Succeeds when the work that runs without the page is running. On a desktop that is automatic import, which the core starts and stops
# as the setting changes and says so in the app's log each time, and syncing, which is allowed while the page's last word on it (the
# "Sync gate set to" line) was true and a database is open. Read from the app's log rather than asked of the app, because the page may
# be doing something else. Usage: linux_background_work_running
#
linux_background_work_running() {
    local app_log="$TMP_DIR/app.log"
    local imports_started
    local imports_stopped
    imports_started="$(grep -nE "Starting automatic import into|Automatic import enabled|Started the background automatic import\." "$app_log" | tail -1 | cut -d: -f1 || true)"
    imports_stopped="$(grep -nE "Stopping automatic import\.|Automatic import disabled|Stopped the background automatic import\." "$app_log" | tail -1 | cut -d: -f1 || true)"
    if [ -n "$imports_started" ] && [ "$imports_started" -gt "${imports_stopped:-0}" ]; then
        return 0
    fi
    local last_sync_gate
    last_sync_gate="$(grep "Sync gate set to" "$app_log" | tail -1 || true)"
    if [[ "$last_sync_gate" == *"Sync gate set to true" ]] && grep -q "Database opened" "$app_log"; then
        return 0
    fi
    return 1
}

#
# Prints what the app has said about its work, for a failure to show. Usage: linux_dump_background_diagnostics
#
linux_dump_background_diagnostics() {
    tail -40 "$TMP_DIR/app.log" || true
}

#
# The log line that says syncing was switched off, as this platform's app writes it. Usage: linux_sync_stopped_log
#
linux_sync_stopped_log() {
    echo "Sync gate set to false"
}

#
# A desktop is always started on a directory of its own that nothing else uses, so its data is wiped by being new and the settings of a
# real phone are never borrowed. A scenario that reached these on a desktop would be about to damage something, so they refuse.
# Usage: linux_borrow_app_settings, linux_return_app_settings
#
linux_borrow_app_settings() {
    echo "linux_borrow_app_settings: a desktop's data is always wiped, so nothing is ever borrowed." >&2
    return 1
}

linux_return_app_settings() {
    echo "linux_return_app_settings: a desktop's data is always wiped, so nothing is ever borrowed." >&2
    return 1
}

#
# Makes the app notice a settings file that was changed from outside it. A desktop reads its settings when it starts and acts on the
# ones it writes itself, so it is stopped and started again on the same data. Usage: linux_apply_settings_change
#
linux_apply_settings_change() {
    stop_app "$APP_PORT" "$TMP_DIR"
    reset_log_cursor "$TMP_DIR"
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"
}

#
# Has the app open the given database when it starts, by naming it as the database to reopen in its databases.toml. A desktop syncs
# the database that is open, so without this nothing is open for the sync to push. Written before the app starts.
# Usage: linux_open_database_on_launch <database_path>
#
linux_open_database_on_launch() {
    local databases_file="$TMP_DIR/config/databases.toml"
    if [ ! -f "$databases_file" ]; then
        echo "linux_open_database_on_launch: there is no $databases_file to name the database in" >&2
        return 1
    fi
    local rendered
    rendered="$(mktemp)"
    {
        echo "last_database = $(jq -n --arg path "$1" '$path')"
        grep -v '^last_database = ' "$databases_file"
    } > "$rendered"
    mv "$rendered" "$databases_file"
}

#
# Prints the app's databases.toml as it stands, or nothing when there is none yet. Usage: linux_read_databases_config
#
linux_read_databases_config() {
    if [ -f "$TMP_DIR/config/databases.toml" ]; then
        cat "$TMP_DIR/config/databases.toml"
    fi
}

#
# Turns the screen off. A desktop's window has no screen to turn off, and its work runs the same either way. Usage: linux_screen_off
#
linux_screen_off() {
    echo "A desktop has no screen to turn off: the core runs its work whatever the display is doing." >&2
}

#
# Forgets what the app has said so far, by remembering which app wrote the log and how long the log is, and prints what it has said
# since. A desktop's sync passes are in the app's own log. Each start of the app writes its log afresh, so the length only counts while
# the same app is running: once another has been started, everything in the log came after the clear. Usage: linux_clear_background_log,
# linux_background_log
#
linux_clear_background_log() {
    echo "$(cat "$TMP_DIR/app.pid") $(wc -l < "$TMP_DIR/app.log" | tr -d ' ')" > "$TMP_DIR/background-log-cursor.txt"
}

linux_background_log() {
    local cursor=0
    local cursor_pid
    local cursor_lines
    if [ -f "$TMP_DIR/background-log-cursor.txt" ]; then
        read -r cursor_pid cursor_lines < "$TMP_DIR/background-log-cursor.txt"
        if [ "$cursor_pid" = "$(cat "$TMP_DIR/app.pid")" ]; then
            cursor="$cursor_lines"
        fi
    fi
    tail -n +$((cursor + 1)) "$TMP_DIR/app.log"
}

#
# Succeeds when a sync pass ran (the loop reported "Syncing" a database, or that it was not syncing) since linux_clear_background_log. Usage: linux_sync_pass_seen
#
linux_sync_pass_seen() {
    linux_background_log | grep -qE 'Syncing "|Not syncing'
}

#
# Prints the directory of the database of the given name as the app has it: one a scenario seeded into the scenario's files directory,
# or else the one the app made for itself inside its data directory. Never the host's own copy that a scenario seeded from. Prints
# nothing when there is none. Usage: linux_app_database_dir <database_dir_name>
#
linux_app_database_dir() {
    if [ -d "$TMP_DIR/files/$1" ]; then
        echo "$TMP_DIR/files/$1"
        return 0
    fi
    find "$TMP_DIR/data" -type d -name "$1" -print -quit 2>/dev/null || true
}

#
# The log line that says automatic import was switched off, as this platform's app writes it. The core's own "Stopping automatic import."
# is written only when an import is running at that moment, and a desktop's import ends between passes, so the page's line is the one
# that is always written. Usage: linux_auto_import_stopped_log
#
linux_auto_import_stopped_log() {
    echo "Automatic import disabled"
}

#
# Asks for the open database to be synced soon, by telling the app the database was edited, which is what makes a desktop schedule a
# sync. A desktop syncs after an edit and on a timer of several minutes, and an automatic import is neither, so a photo it took in
# reaches the origin at the next timer tick unless this is sent. Usage: linux_request_sync <port>
#
linux_request_sync() {
    send_command "$1" notify-database-edited '{}'
}
