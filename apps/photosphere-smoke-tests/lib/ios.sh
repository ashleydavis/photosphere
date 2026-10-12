#!/usr/bin/env bash

# The iOS platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# When an iPhone or iPad is connected the scenarios run on it, as run-ios.sh runs the app there, and ios-device.sh, sourced below,
# replaces everything here. Otherwise the app runs on an iOS simulator that already exists: PHOTOSPHERE_IOS_SIMULATOR names one,
# otherwise a running one or the first available iPhone is used (see apple_pick_simulator). Nothing is created or deleted.
#
# A simulator process shares the host's file system and network, so the control port file, the settings, the vault and the logs are
# host paths inside the scenario's directory, and the control connection is reached at 127.0.0.1. Variables named SIMCTL_CHILD_<name>
# reach the app's environment as <name>. The app's process is not a child of this shell, so it is recorded by its process id and stopped
# with simctl. The core writes its log to a file, and the scenario reads app.log, so a tail of the log file writes app.log.

IOS_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"
source "$IOS_SCRIPTS_DIR/lib/apple-common.sh"

#
# Stops the scenario with a message naming the helper that has no iOS implementation yet, for the helpers the scenarios call as
# ${PLATFORM}_<name>. A scenario that reaches one fails here, loudly, and does not carry on as if the work had been done.
# Usage: photosphere_ios_not_available <helper name>
#
photosphere_ios_not_available() {
    echo "not available on iOS yet: $1" >&2
    exit 1
}

#
# The name scenarios call to clear the app's stored data, which is ${PLATFORM}_reset_app_state. Defined for the simulator and for a
# connected device alike, because each defines photosphere_platform_reset_app_state.
#
ios_reset_app_state() {
    photosphere_platform_reset_app_state
}

if [ -n "$(apple_connected_device)" ]; then
    source "$PHOTOSPHERE_SMOKE_DIR/lib/ios-device.sh"
    return 0
fi

# The app's bundle identifier.
IOS_BUNDLE_ID="au.com.codecapers.photosphere.ziggy"

# The files the simulator's identifier and the app's process id are recorded in, per scenario.
IOS_UDID_FILE_NAME="simulator.udid"
IOS_PID_FILE_NAME="app.pid"

# The simulator the run uses, chosen the first time it is needed.
IOS_SIMULATOR_UDID=""

#
# Chooses the simulator once, booting it when it is not running, and sets IOS_SIMULATOR_UDID. A later call keeps the choice, so the
# reset before a start and the start itself use the same one.
#
photosphere_ios_pick_simulator() {
    if [ -n "$IOS_SIMULATOR_UDID" ]; then
        return 0
    fi
    IOS_SIMULATOR_UDID="$(apple_pick_simulator)" || return 1
}

#
# Prints how many devices scenarios can run on at once. The run uses one simulator, and a simulator runs one copy of the app.
#
photosphere_platform_device_limit() {
    echo 1
}

photosphere_platform_prepare() {
    local run_dir="$1"
    bash "$IOS_SCRIPTS_DIR/build-ios.sh" --sdk simulator --test-hooks --configuration Release --native-dir "$run_dir/test-native" --build-dir "$run_dir/test-build" || return 1
}

#
# Starts the app for one scenario. Sets PHOTOSPHERE_CONTROL_HOST and PHOTOSPHERE_CONTROL_PORT to where the test control connection can
# be reached. A fresh start installs the app; with keep-data it starts the installed app again on the data the last run left.
# Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/test-build/Build/Products/Release-iphonesimulator/Photosphere.app"
    local port_file="$test_dir/control-port.txt"
    rm -f "$port_file"
    mkdir -p "$test_dir"
    photosphere_ios_pick_simulator || return 1
    local udid="$IOS_SIMULATOR_UDID"
    echo "$udid" > "$test_dir/$IOS_UDID_FILE_NAME"
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    # Terminating first fails when the app is not running, which is the usual case and not an error. A restart does not install
    # again, which keeps the app's data.
    xcrun simctl terminate "$udid" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    if [ "${2:-}" != "keep-data" ]; then
        xcrun simctl install "$udid" "$app" || return 1
        echo 0 > "$test_dir/log-generation.txt"
    fi

    # Each start writes its log to a directory of its own, so the tail below copies only this start's log, as the desktop's app.log
    # holds only the run it belongs to.
    local generation
    generation=$(($(cat "$test_dir/log-generation.txt") + 1))
    echo "$generation" > "$test_dir/log-generation.txt"
    local log_dir="$test_dir/logs-$generation"

    local launched
    launched="$(SIMCTL_CHILD_PHOTOSPHERE_TEST_MODE=1 \
        SIMCTL_CHILD_PHOTOSPHERE_CONFIG_DIR="$test_dir/config" \
        SIMCTL_CHILD_PHOTOSPHERE_VAULT_DIR="$test_dir/vault" \
        SIMCTL_CHILD_PHOTOSPHERE_VAULT_TYPE=plaintext \
        SIMCTL_CHILD_PHOTOSPHERE_LOG_DIR="$log_dir" \
        SIMCTL_CHILD_PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        SIMCTL_CHILD_TEST_TMP_DIR="$test_dir" \
        SIMCTL_CHILD_ZIGGY_TEST_MODE=1 \
        SIMCTL_CHILD_ZIGGY_TEST_PORT_FILE="$port_file" \
        xcrun simctl launch "$udid" "$IOS_BUNDLE_ID")" || return 1
    local pid="${launched##*: }"
    echo "$pid" > "$test_dir/$IOS_PID_FILE_NAME"

    # The log file appears when the core is created. The pattern matches the main log and not the errors log beside it.
    local log_files=()
    local waited=0
    while true; do
        log_files=("$log_dir"/logs/photosphere-????-??-??T??-??-??.log)
        if [ -f "${log_files[0]}" ]; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "The app exited before it made its log. simctl said: $launched" >&2
            return 1
        fi
        if [ "$waited" -ge 600 ]; then
            echo "The app never made its log file." >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    local tail_pid tail_pgid
    read -r tail_pid tail_pgid < <(launch_in_process_group "$test_dir/app.log" tail -n +1 -f "${log_files[0]}") || return 1
    echo "$tail_pgid" > "$test_dir/log-stream.pgid"

    waited=0
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
# Stops the app and the tail of its log. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$IOS_UDID_FILE_NAME" ]; then
        # Fails when the app has already exited, which is a normal end for a scenario that quit it.
        xcrun simctl terminate "$(cat "$test_dir/$IOS_UDID_FILE_NAME")" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    fi
    if [ -s "$test_dir/log-stream.pgid" ]; then
        kill_process_group "$(cat "$test_dir/log-stream.pgid")" || true
        : > "$test_dir/log-stream.pgid"
    fi
}

#
# Waits for the app to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local pid
    pid="$(cat "$test_dir/$IOS_PID_FILE_NAME")"
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Succeeds when the app's process is running. Usage: photosphere_platform_is_running <test_dir>
#
photosphere_platform_is_running() {
    kill -0 "$(cat "$1/$IOS_PID_FILE_NAME")" 2>/dev/null
}

#
# Clears everything the app has stored on the simulator, as the mobile suite's ios_reset_app_state does: uninstalling the app removes
# its container (Documents, Library and the web view's storage), and the simulator's keychain, which holds items outside the container,
# is reset. Call it before the start, which installs the app again. An app that is not installed has no container to remove.
#
photosphere_platform_reset_app_state() {
    photosphere_ios_pick_simulator || return 1
    if xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" > /dev/null 2>&1; then
        xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
        xcrun simctl uninstall "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" || return 1
    fi
    xcrun simctl keychain "$IOS_SIMULATOR_UDID" reset || {
        echo "Could not reset the simulator keychain; a secret from an earlier scenario may still be present." >&2
        return 1
    }
}

#
# The address the simulator uses to reach this host. The simulator shares the host's network, so the host is loopback, as an IPv4
# literal and not the name, which can resolve to ::1.
#
ios_host_address() {
    echo "127.0.0.1"
}

#
# Makes a port the host is listening on reachable from the simulator, which needs nothing: the simulator shares the host's network.
# Usage: ios_expose_host_port <port>
#
ios_expose_host_port() {
    return 0
}

#
# Prints the host path of the app's data container on the simulator. The container exists once the app is installed, which the start
# does, so a scenario seeds after its start (or after a start that kept the data). Fails, saying so, when the app is not installed.
#
photosphere_ios_container() {
    photosphere_ios_pick_simulator || return 1
    local container
    container="$(xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" data 2> /dev/null)" || true
    if [ -z "$container" ]; then
        echo "The app $IOS_BUNDLE_ID is not installed on the simulator $IOS_SIMULATOR_UDID, so it has no data container. Start it first." >&2
        return 1
    fi
    printf '%s\n' "$container"
}

#
# Prints the host path of the app's storage directory, the one the app resolves its storage-relative paths against. It is the data
# directory the shell gives the core, which is the app's Application Support directory named for its bundle identifier.
#
photosphere_ios_storage_root() {
    local container
    container="$(photosphere_ios_container)" || return 1
    printf '%s\n' "$container/Library/Application Support/$IOS_BUNDLE_ID"
}

#
# Prints the host path of the app's settings directory, which photosphere_platform_start gives the app as PHOTOSPHERE_CONFIG_DIR: a
# directory named config in the directory of the app that was started last, or in the scenario's own when none has been started.
#
photosphere_ios_config_dir() {
    printf '%s\n' "${APP_TMP_DIR:-$TMP_DIR}/config"
}

#
# Prints the absolute path, on the host, of a name inside the app's storage directory, which is where ios_seed_database puts a
# fixture. The app resolves no relative path against its storage, so a scenario types or writes this path rather than the name.
# Usage: ios_app_path <relative_path_under_storage>
#
ios_app_path() {
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    printf '%s\n' "$root/$1"
}

#
# Copies a database fixture from the host into the app's storage directory, the place ios_app_path names. A copy already there is made
# to match the fixture. The simulator's container is on the host filesystem, so a copy is enough. <relative_dest> is relative to the
# storage directory.
# Usage: ios_seed_database <host_fixture_dir> <relative_dest_under_storage>
#
ios_seed_database() {
    local host_src="$1"
    local rel_dest="$2"
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    mkdir -p "$root/$rel_dest" || return 1
    rsync -a --delete "$host_src/" "$root/$rel_dest/" || return 1
    echo "Seeded database fixture '$(basename "$host_src")' into the app's storage directory at $rel_dest" >&2
}

#
# Writes the app's databases.toml into its settings directory, registering the given databases and recent-database names, from outside
# the app, as a desktop scenario pre-writes the file. The first two arguments are JSON: the databases as an array of {name, path}
# (description, origin, s3Key, encryptionKey and geocodingKey optional), and the recents as an array of names, empty when omitted. The
# third is the path of the database the app reopens on launch; omitted, no such key is written, which leaves the app on the welcome
# screen. Paths are written as given.
# Usage: ios_seed_databases_config '<databases json>' ['<recent names json>'] ['<last database path>']
#
ios_seed_databases_config() {
    local databases_json="$1"
    local recent_json="${2:-[]}"
    local last_database="${3:-}"
    local config_dir
    config_dir="$(photosphere_ios_config_dir)"
    mkdir -p "$config_dir" || return 1
    local rendered="$config_dir/databases.toml.seeding"
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
    ' > "$rendered"; then
        echo "Could not render the app's database list from: $databases_json" >&2
        rm -f "$rendered"
        return 1
    fi
    mv "$rendered" "$config_dir/databases.toml" || return 1
    echo "Wrote the app's database list to $config_dir/databases.toml" >&2
}

#
# Prints the app's databases.toml as it stands in its settings directory, or nothing when there is none yet, which is how a scenario
# asserts on a write the app made. Usage: ios_read_databases_config
#
ios_read_databases_config() {
    local file
    file="$(photosphere_ios_config_dir)/databases.toml"
    if [ -f "$file" ]; then
        cat "$file"
    fi
}

#
# Writes the syncing settings into the sync section of the app's config.yaml in its settings directory, keeping every other section
# the file already has. A database path says which database the background sync pushes, which the app otherwise records itself when
# one is opened. The pause is left out, so the app's default applies, when none is given.
# Usage: ios_seed_sync_config <enabled true|false> <only_on_wifi true|false> [pause_ms] [database_path]
#
ios_seed_sync_config() {
    local enabled="$1"
    local only_on_wifi="$2"
    local pause_ms="${3:-}"
    local database_path="${4:-}"
    local value
    for value in "$enabled" "$only_on_wifi"; do
        if [ "$value" != "true" ] && [ "$value" != "false" ]; then
            echo "ios_seed_sync_config takes true or false for enabled and only_on_wifi, got: $value" >&2
            return 1
        fi
    done
    if [ -n "$pause_ms" ] && ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "ios_seed_sync_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    local config_dir
    config_dir="$(photosphere_ios_config_dir)"
    mkdir -p "$config_dir" || return 1
    local file="$config_dir/config.yaml"
    local rendered="$config_dir/config.yaml.seeding"

    # The file as it stands, minus its sync section, which runs from the line "sync:" to the next line that is not indented.
    : > "$rendered"
    if [ -f "$file" ]; then
        tr -d '\r' < "$file" | sed -e '/^sync:/,/^[^[:space:]]/{/^sync:/d;/^[[:space:]]/d}' > "$rendered" || return 1
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
    mv "$rendered" "$file" || return 1
    echo "Wrote the app's syncing settings to $file (enabled=$enabled, onlyOnWifi=$only_on_wifi)" >&2
}

#
# Writes the automatic import settings into the auto_import section of the app's config.yaml in its settings directory, keeping every
# other section the file already has. An album id restricts the import to that one album of the photo library. The default database path
# must be a path the app can open, so a scenario passes ios_app_path of the database; left out, the app makes its own default database.
# The pause between passes is left out, so the app's default applies, when none is given.
# Usage: ios_seed_auto_import_config <enabled true|false> [default_database_path] [pause_ms] [album_id]
#
ios_seed_auto_import_config() {
    local enabled="$1"
    local default_database_path="${2:-}"
    local pause_ms="${3:-}"
    local album_id="${4:-}"
    if [ "$enabled" != "true" ] && [ "$enabled" != "false" ]; then
        echo "ios_seed_auto_import_config takes true or false for enabled, got: $enabled" >&2
        return 1
    fi
    if [ -n "$pause_ms" ] && ! [[ "$pause_ms" =~ ^[0-9]+$ ]]; then
        echo "ios_seed_auto_import_config takes a whole number of milliseconds for the pause, got: $pause_ms" >&2
        return 1
    fi
    local config_dir
    config_dir="$(photosphere_ios_config_dir)"
    mkdir -p "$config_dir" || return 1
    local file="$config_dir/config.yaml"
    local rendered="$config_dir/config.yaml.seeding"

    # The file as it stands, minus its auto_import section, which runs from the line "auto_import:" to the next line that is not indented.
    : > "$rendered"
    if [ -f "$file" ]; then
        tr -d '\r' < "$file" | sed -e '/^auto_import:/,/^[^[:space:]]/{/^auto_import:/d;/^[[:space:]]/d}' > "$rendered" || return 1
    fi
    {
        echo "auto_import:"
        echo "  enabled: $enabled"
        if [ -n "$pause_ms" ]; then
            echo "  pause_between_runs_ms: $pause_ms"
        fi
        if [ -n "$album_id" ]; then
            echo "  sources:"
            echo "    - type: device-album"
            echo "      album_id: $(jq -n --arg album "$album_id" '$album')"
        fi
        if [ -n "$default_database_path" ]; then
            echo "  default_database_path: $(jq -n --arg path "$default_database_path" '$path')"
        fi
    } >> "$rendered"
    mv "$rendered" "$file" || return 1
    echo "Wrote the app's automatic import settings to $file (enabled=$enabled)" >&2
}

#
# Grants the app the photo library permission from outside the app, so no permission dialog has to be tapped. The app asks for it with
# the system's own request, which is answered at once once it has been granted.
# Usage: ios_grant_media_permission
#
ios_grant_media_permission() {
    photosphere_ios_pick_simulator || return 1
    if ! xcrun simctl privacy "$IOS_SIMULATOR_UDID" grant photos "$IOS_BUNDLE_ID"; then
        echo "Could not grant the photo library permission to $IOS_BUNDLE_ID on the simulator $IOS_SIMULATOR_UDID, so the app would wait on a dialog no scenario can tap." >&2
        return 1
    fi
    echo "Granted the photo library permission from outside the app" >&2
}

#
# The notification permission needs no granting on iOS: the app shows no notification while the background work runs, and asks for no
# permission to. Says so and succeeds, so a scenario written for both phones reads the same on either.
# Usage: ios_grant_notification_permission
#
ios_grant_notification_permission() {
    echo "The app asks for no notification permission on iOS, so there is nothing to grant" >&2
}

#
# Removes a path under the app's storage directory so a scenario that creates fresh state there can be run again. A file is removed
# and an empty directory is removed. A directory with anything in it fails, because removing a tree needs a recursive delete, which
# this library has not been given approval for.
# Usage: ios_reset_path <relative_path_under_storage>
#
ios_reset_path() {
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    local target="$root/$1"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    if [ -d "$target" ] && [ ! -L "$target" ]; then
        rmdir "$target" || {
            echo "ios_reset_path cannot remove $target: it is a directory with something in it, and removing it needs a recursive delete." >&2
            return 1
        }
        return 0
    fi
    rm -f "$target"
}

#
# Waits until the given path under the app's storage directory exists and is non-empty (for a directory, lists at least one entry), to
# see a background task's effect on storage. Returns 0 once it is there, non-zero after DEFAULT_WAIT_TIMEOUT seconds.
# Usage: ios_wait_for_file <relative_path_under_storage>
#
ios_wait_for_file() {
    local rel="$1"
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    local target="$root/$rel"
    local deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -d "$target" ]; then
            if [ -n "$(ls -A "$target")" ]; then
                return 0
            fi
        elif [ -s "$target" ]; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    return 1
}

#
# Prints the path of a file in the app's settings directory. Usage: ios_config_file_path <name>
#
ios_config_file_path() {
    echo "$(photosphere_ios_config_dir)/$1"
}

#
# Puts a file from the host into the app's settings directory from outside the app, replacing one of the same name. Usage: ios_put_config_file <host_file> <name>
#
ios_put_config_file() {
    mkdir -p "$(photosphere_ios_config_dir)" || return 1
    cp "$1" "$(photosphere_ios_config_dir)/$2"
}

#
# Prints a file of the app's settings directory, or nothing when there is none. Usage: ios_read_config_file <name>
#
ios_read_config_file() {
    local file
    file="$(photosphere_ios_config_dir)/$1"
    if [ -f "$file" ]; then
        cat "$file"
    fi
}

#
# Succeeds when a path under the app's storage directory exists, whether a file or a directory. Usage: ios_path_exists <relative_path_under_storage>
#
ios_path_exists() {
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    [ -e "$root/$1" ]
}

#
# Writes a PNG of the simulator's screen to a host path, with simctl. The app cannot do this itself from outside its own window.
# Fails when nothing was written or what was written is not a PNG.
# Usage: photosphere_platform_screenshot <output_path>
#
photosphere_platform_screenshot() {
    local output_path="$1"
    if [ -z "$IOS_SIMULATOR_UDID" ]; then
        echo "No simulator is chosen, so there is no screen to capture." >&2
        return 1
    fi
    mkdir -p "$(dirname "$output_path")"
    xcrun simctl io "$IOS_SIMULATOR_UDID" screenshot --type=png "$output_path" > /dev/null || {
        echo "simctl screenshot failed on $IOS_SIMULATOR_UDID" >&2
        return 1
    }
    if [ "$(od -An -tx1 -N8 "$output_path" | tr -d ' \n')" != "89504e470d0a1a0a" ]; then
        echo "simctl screenshot on $IOS_SIMULATOR_UDID wrote something that is not a PNG to $output_path" >&2
        return 1
    fi
}

#
# Makes the next download end as the user cancelling it. A phone hands a download to the system share sheet, which a test cannot tap,
# so the sheet's outcome is staged as cancelled through the page. Usage: ios_cancel_next_download <port>
#
ios_cancel_next_download() {
    send_command "$1" stage-export '{"exportOutcome":"cancelled"}'
}
