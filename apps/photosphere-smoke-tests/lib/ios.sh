#!/usr/bin/env bash

# The iOS platform library of Photosphere's smoke tests. See common.sh for what it implements.
#
# When an iPhone or iPad is connected the scenarios run on it, as run-ios.sh runs the app there, and ios-device.sh, sourced below,
# replaces everything here. Otherwise the app runs on an iOS simulator that already exists: PHOTOSPHERE_IOS_SIMULATOR names one,
# otherwise a running one or the first available iPhone is used (see apple_pick_simulator). Nothing is created or deleted.
#
# A simulator process shares the host's file system and network, so the settings, the vault and the logs are
# host paths inside the scenario's directory, and the app reaches its remote control server at 127.0.0.1. Variables named SIMCTL_CHILD_<name>
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

#
# The line the app logs when automatic import starts, which the page says once the photo permission has had its say. The same on the
# simulator and on a connected device, because it is the page's. Usage: ios_auto_import_started_log
#
ios_auto_import_started_log() {
    echo "Starting automatic import."
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
# Claims the simulator for this scenario, waiting while a scenario of another run holds it, because every run picks the same simulator
# and the app's bundle identifier is the same in each, so two scenarios at once would stop, uninstall and wipe each other's app. The
# lock is a directory, made atomically by mkdir, holding the process id of the scenario's shell, as the claim on a connected device in
# ios-device.sh is. A lock left by a scenario that has ended, or was killed, is taken over. The scenario never lets go: its shell ending
# is what frees the simulator. A lock this scenario's own shell holds is already claimed, which is what a subshell of the scenario
# (a $(...) that reaches here) finds. Usage: photosphere_ios_claim_simulator <udid>
#
photosphere_ios_claim_simulator() {
    local udid="$1"
    local lock_dir="${TMPDIR:-/tmp}/photosphere-ios-simulator-$udid.lock"
    local waited=0
    local owner
    while ! mkdir "$lock_dir" 2>/dev/null; do
        owner="$(cat "$lock_dir/owner" 2>/dev/null || true)"
        if [ "$owner" = "$$" ]; then
            return 0
        fi
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "Taking over the lock on the simulator $udid from scenario process $owner, which has gone." >&2
            rm -f "$lock_dir/owner"
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        if [ "$waited" -ge 1800 ]; then
            echo "The simulator $udid was not free within 1800s; scenario process ${owner:-unknown} holds it." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "$$" > "$lock_dir/owner"
}

#
# Chooses the simulator once, booting it when it is not running, claims it for this scenario, and sets IOS_SIMULATOR_UDID. A later call
# keeps the choice, so the reset before a start and the start itself use the same one.
#
photosphere_ios_pick_simulator() {
    if [ -n "$IOS_SIMULATOR_UDID" ]; then
        return 0
    fi
    local udid
    udid="$(apple_pick_simulator)" || return 1
    photosphere_ios_claim_simulator "$udid" || return 1
    IOS_SIMULATOR_UDID="$udid"
}

#
# Prints how many devices scenarios can run on at once. The run uses one simulator, and a simulator runs one copy of the app.
#
photosphere_platform_device_limit() {
    echo 1
}

photosphere_platform_prepare() {
    local run_dir="$1"
    local build="${PHOTOSPHERE_SMOKE_BUILD:-}"
    if [ -z "$build" ]; then
        build="$run_dir/build"
        bash "$IOS_SCRIPTS_DIR/build-ios.sh" --sdk simulator --configuration Release --native-dir "$build/native" --build-dir "$build/xcode" || return 1
    fi
    local built_app="$build/xcode/Build/Products/Release-iphonesimulator/Photosphere.app"
    if [ ! -d "$built_app" ]; then
        echo "The iOS simulator build $build has no xcode/Build/Products/Release-iphonesimulator/Photosphere.app." >&2
        return 1
    fi
    mkdir -p "$run_dir/app"
    cp -R "$built_app" "$run_dir/app/" || return 1
}

#
# Installs the app the run built on the chosen simulator, once per scenario. Installing again keeps the app's data but moves its
# container to a new path, so a database path the scenario seeded or the app saved would then name nothing; a file in the scenario's
# directory records that this scenario has installed, and a later call does nothing. The reset removes the file before it installs.
#
photosphere_ios_install() {
    photosphere_ios_pick_simulator || return 1
    if [ -f "$TMP_DIR/ios-installed" ]; then
        return 0
    fi
    xcrun simctl install "$IOS_SIMULATOR_UDID" "$PHOTOSPHERE_SMOKE_RUN_DIR/app/Photosphere.app" || return 1
    : > "$TMP_DIR/ios-installed"
}

#
# Starts the app for one scenario, with --remote-control and the address of the scenario's remote control server, which it starts
# first. A fresh start installs the app; with keep-data it starts the installed app again on the data the last run left.
# Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    mkdir -p "$test_dir"
    photosphere_ios_pick_simulator || return 1
    local udid="$IOS_SIMULATOR_UDID"
    echo "$udid" > "$test_dir/$IOS_UDID_FILE_NAME"
    photosphere_start_remote_control_server "$test_dir" || return 1
    if ! process_control_verify_job_control; then
        echo "Cannot start the app without a process group of its own; see the error above." >&2
        return 1
    fi
    # Terminating first fails when the app is not running, which is the usual case and not an error. A restart does not install
    # again, which keeps the app's data.
    xcrun simctl terminate "$udid" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    # Installs the run's build unless this scenario already has, so a later start is a restart of the installed app, as on Android.
    # The log generation is counted from the first start, so each later start gets a log directory of its own.
    if [ "${2:-}" != "keep-data" ]; then
        photosphere_ios_install || return 1
    fi
    if [ ! -f "$test_dir/log-generation.txt" ]; then
        echo 0 > "$test_dir/log-generation.txt"
    fi

    # Each start writes its log to a directory of its own, so the tail below copies only this start's log, as the desktop's app.log
    # holds only the run it belongs to.
    local generation
    generation=$(($(cat "$test_dir/log-generation.txt") + 1))
    echo "$generation" > "$test_dir/log-generation.txt"
    local log_dir="$test_dir/logs-$generation"

    # The background work's passes report to the system log, not to the core's log file (see ios_background_log), so the simulator's
    # system log is streamed into a file of this start's own, and is streaming before the app is launched so nothing the first pass says
    # is missed. The stream prints its "Filtering" line once it is running.
    local background_log_file="$test_dir/background-$generation.log"
    local stream_pid stream_pgid
    read -r stream_pid stream_pgid < <(launch_in_process_group "$background_log_file" xcrun simctl spawn "$udid" log stream --level info --style compact --predicate "subsystem == \"$IOS_BUNDLE_ID\" AND category == \"AutoImportService\"") || return 1
    echo "$stream_pgid" > "$test_dir/background-stream.pgid"
    local stream_waited=0
    while ! grep -q "^Filtering the log data" "$background_log_file"; do
        if ! kill -0 "$stream_pid" 2>/dev/null; then
            echo "The simulator's system log stream ended before it started streaming. It said:" >&2
            cat "$background_log_file" >&2
            return 1
        fi
        if [ "$stream_waited" -ge 300 ]; then
            echo "The simulator's system log stream did not start streaming within 30s. It said:" >&2
            cat "$background_log_file" >&2
            return 1
        fi
        sleep 0.1
        stream_waited=$((stream_waited + 1))
    done

    local launched
    launched="$(SIMCTL_CHILD_PHOTOSPHERE_TEST_MODE=1 \
        SIMCTL_CHILD_PHOTOSPHERE_CONFIG_DIR="$test_dir/config" \
        SIMCTL_CHILD_PHOTOSPHERE_VAULT_DIR="$test_dir/vault" \
        SIMCTL_CHILD_PHOTOSPHERE_VAULT_TYPE=plaintext \
        SIMCTL_CHILD_PHOTOSPHERE_LOG_DIR="$log_dir" \
        SIMCTL_CHILD_PHOTOSPHERE_NEWS_URL="${PHOTOSPHERE_NEWS_URL:-}" \
        SIMCTL_CHILD_TEST_TMP_DIR="$test_dir" \
        xcrun simctl launch "$udid" "$IOS_BUNDLE_ID" --remote-control "$PHOTOSPHERE_REMOTE_CONTROL")" || return 1
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
}

#
# Stops the app, the tail of its log and the stream of the system log. Stopping simctl stops the log process it spawned in the
# simulator, because simctl hands the signal on to it. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    if [ -f "$test_dir/$IOS_UDID_FILE_NAME" ]; then
        # Fails when the app has already exited, which is a normal end for a scenario that quit it.
        xcrun simctl terminate "$(cat "$test_dir/$IOS_UDID_FILE_NAME")" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
    fi
    local stream_name
    for stream_name in log-stream background-stream; do
        if [ -s "$test_dir/$stream_name.pgid" ]; then
            kill_process_group "$(cat "$test_dir/$stream_name.pgid")" || true
            : > "$test_dir/$stream_name.pgid"
        fi
    done
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
# is reset. The app is then installed again, so its empty container is there for a scenario to seed before its start, as the reset on
# Android leaves the app installed with its data cleared. An app that is not installed has no container to remove. The photo permission
# is put back to never having been asked, as clearing an Android app's data does, because it is kept by the simulator and not in the
# container, so a scenario that refused it would otherwise leave every later scenario refused.
#
photosphere_platform_reset_app_state() {
    photosphere_ios_pick_simulator || return 1
    if xcrun simctl get_app_container "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" > /dev/null 2>&1; then
        xcrun simctl terminate "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" > /dev/null 2>&1 || true
        xcrun simctl uninstall "$IOS_SIMULATOR_UDID" "$IOS_BUNDLE_ID" || return 1
    fi
    rm -f "$TMP_DIR/ios-installed"
    photosphere_ios_install || return 1
    xcrun simctl privacy "$IOS_SIMULATOR_UDID" reset photos "$IOS_BUNDLE_ID" || {
        echo "Could not reset the photo library permission of $IOS_BUNDLE_ID on the simulator $IOS_SIMULATOR_UDID; a refusal from an earlier scenario may still be in force." >&2
        return 1
    }
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
# Prints the host path of the app's data container on the simulator. The container exists once the app is installed, so the scenario's
# install is made first if it has not been, as the Android seed helpers install the app before they seed.
#
photosphere_ios_container() {
    photosphere_ios_install || return 1
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
# directory the native app gives the core, which is the app's Application Support directory named for its bundle identifier.
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
# Copies a database out of the app's storage directory to a directory on the host, so the host's CLI can read what the app wrote. The
# simulator's container is on the host filesystem, so a copy is enough. The destination must not exist.
# Usage: ios_fetch_database <relative_path_under_storage> <host_dest>
#
ios_fetch_database() {
    local rel_path="$1"
    local host_dest="$2"
    local root
    root="$(photosphere_ios_storage_root)" || return 1
    if [ ! -d "$root/$rel_path" ]; then
        echo "$rel_path is not a directory in the app's storage directory ($root), so nothing was copied out" >&2
        return 1
    fi
    mkdir -p "$host_dest" || return 1
    rsync -a "$root/$rel_path/" "$host_dest/" || return 1
    if [ -z "$(ls -A "$host_dest")" ]; then
        echo "$rel_path held nothing, so nothing was copied out of the app's storage directory" >&2
        return 1
    fi
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
        tr -d '\r' < "$file" | sed -e '/^sync:/,/^[^[:space:]]/{' -e '/^sync:/d' -e '/^[[:space:]]/d' -e '}' > "$rendered" || return 1
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

    # simctl (Xcode 14.2) records the grant at version 1 of the permission scheme. iOS 14 and later read the photo permission at
    # version 2 and take a version 1 grant to mean "not asked yet", so PHPhotoLibrary.requestAuthorization raises a prompt the system
    # holds back and never answers, and the app waits on it for good. The record is moved to version 2, which is what the user allowing
    # full access in the dialog writes.
    local tcc_db
    tcc_db="$(xcrun simctl getenv "$IOS_SIMULATOR_UDID" HOME)/Library/TCC/TCC.db" || return 1
    local updated
    updated="$(sqlite3 "$tcc_db" "UPDATE access SET auth_version = 2 WHERE service = 'kTCCServicePhotos' AND client = '$IOS_BUNDLE_ID' AND auth_value = 2; SELECT changes();")" || return 1
    if [ "$updated" != "1" ]; then
        echo "The photo library grant simctl made for $IOS_BUNDLE_ID was not found in $tcc_db ($updated rows updated), so the app would wait on a dialog no scenario can tap." >&2
        return 1
    fi
    echo "Granted the photo library permission from outside the app" >&2
}

#
# Refuses the app the photo library permission from outside the app, as a user who chose "Don't Allow": the app's next request is
# answered "denied" without a dialog. Done with the app stopped, because changing a permission terminates an app that is running.
# Usage: ios_refuse_media_permission
#
ios_refuse_media_permission() {
    photosphere_ios_pick_simulator || return 1
    if ! xcrun simctl privacy "$IOS_SIMULATOR_UDID" revoke photos "$IOS_BUNDLE_ID"; then
        echo "Could not refuse the photo library permission to $IOS_BUNDLE_ID on the simulator $IOS_SIMULATOR_UDID." >&2
        return 1
    fi
    echo "Refused the photo library permission, as a user who chose \"Don't Allow\"" >&2
}

#
# Succeeds when the core's background work (automatic import, sync and prefetch) is running. iOS has no foreground service to list, so
# the work is read from the app's log: the core logs a line when the page starts it and another when the page stops it, and it is
# running when the last start is later than the last stop. Usage: ios_background_work_running
#
ios_background_work_running() {
    local app_log="$TMP_DIR/app.log"
    local started
    local stopped
    started="$(grep -n "Started the background automatic import\." "$app_log" | tail -1 | cut -d: -f1 || true)"
    stopped="$(grep -n "Stopped the background automatic import\." "$app_log" | tail -1 | cut -d: -f1 || true)"
    [ -n "$started" ] && [ "$started" -gt "${stopped:-0}" ]
}

#
# Waits until the core's background work is not running, as ios_background_work_running reads it. Returns 0 once it is not, non-zero
# when it is still running after the given number of seconds. Usage: ios_wait_for_background_service_gone <seconds>
#
ios_wait_for_background_service_gone() {
    local seconds="$1"
    local waited=0
    while [ "$waited" -lt "$seconds" ]; do
        if ! ios_background_work_running; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
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
# Succeeds when the core's background work (automatic import, sync and prefetch) is switched on in the running app. iOS has no
# foreground service: the core runs the passes itself while the app is on screen, from the moment the page asks for them, which it says
# in the app's log as "Started the background automatic import." and, when both features go off, "Stopped the background automatic
# import.". The last of the two decides, and an app that is no longer running has no work running whatever its log says.
# Usage: ios_background_work_running
#
ios_background_work_running() {
    local test_dir="${APP_TMP_DIR:-$TMP_DIR}"
    if ! photosphere_platform_is_running "$test_dir"; then
        return 1
    fi
    local started stopped
    started="$(grep -n "Started the background automatic import\." "$test_dir/app.log" | tail -1 | cut -d: -f1 || true)"
    stopped="$(grep -n "Stopped the background automatic import\." "$test_dir/app.log" | tail -1 | cut -d: -f1 || true)"
    [ -n "$started" ] && [ "$started" -gt "${stopped:-0}" ]
}

#
# Prints everything the background work has said in the system log since the scenario's first start, oldest first: each start streams it
# into a file of its own (see photosphere_platform_start), and the files are read in the order of the starts.
# Usage: photosphere_ios_background_log_all
#
photosphere_ios_background_log_all() {
    local test_dir="${APP_TMP_DIR:-$TMP_DIR}"
    if [ ! -f "$test_dir/log-generation.txt" ]; then
        return 0
    fi
    local last_generation
    last_generation="$(cat "$test_dir/log-generation.txt")"
    local generation=1
    while [ "$generation" -le "$last_generation" ]; do
        cat "$test_dir/background-$generation.log" || return 1
        generation=$((generation + 1))
    done
}

#
# Prints the lines the background work has written since the last ios_clear_background_log. The passes report what they are doing
# through the native app's backgroundLog, which writes them to the system log under the AutoImportService category rather than to the
# app's log file, as the Android native app writes them to logcat. Usage: ios_background_log
#
ios_background_log() {
    local cursor=0
    local cursor_file="${APP_TMP_DIR:-$TMP_DIR}/background-log-cursor.txt"
    if [ -f "$cursor_file" ]; then
        cursor="$(cat "$cursor_file")"
    fi
    photosphere_ios_background_log_all | tail -n +$((cursor + 1))
}

#
# Forgets what the background work has said so far, by recording how many lines it has said, which ios_background_log then skips.
# The streams of later starts are appended after it, so the count holds across a restart. Usage: ios_clear_background_log
#
ios_clear_background_log() {
    local lines
    lines="$(photosphere_ios_background_log_all | wc -l | tr -d ' ')" || return 1
    echo "$lines" > "${APP_TMP_DIR:-$TMP_DIR}/background-log-cursor.txt"
}

#
# Prints what the app and its background work have said, for a failure to show. Usage: ios_dump_background_diagnostics
#
ios_dump_background_diagnostics() {
    tail -40 "${APP_TMP_DIR:-$TMP_DIR}/app.log" || true
    photosphere_ios_background_log_all | tail -60 || true
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
# Succeeds when a file of the app's settings directory exists, even when it is empty. Usage: ios_config_file_exists <name>
#
ios_config_file_exists() {
    [ -f "$(photosphere_ios_config_dir)/$1" ]
}

#
# Damages the vault the app keeps its secrets in, from outside the app, with the app stopped. On the simulator the app runs in test
# mode with the plaintext vault, a vault.json in the scenario's directory on the host, so it is replaced with something that is not
# JSON, which is what a truncated write leaves behind, and reading the vault fails. Fails when there is no vault to damage.
# Usage: ios_damage_vault
#
ios_damage_vault() {
    local vault_file="${APP_TMP_DIR:-$TMP_DIR}/vault/vault.json"
    if [ ! -f "$vault_file" ]; then
        echo "No vault file at $vault_file to damage; the secret was never stored" >&2
        return 1
    fi
    printf '%s' 'this is not json' > "$vault_file" || return 1
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
