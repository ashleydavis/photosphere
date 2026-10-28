#!/usr/bin/env bash

# The iOS platform library of Photosphere's smoke tests when a device is connected, sourced by ios.sh in place of its
# simulator functions. See common.sh for what it implements.
#
# The app runs on a connected iPhone or iPad: PHOTOSPHERE_IOS_DEVICE names one, otherwise the first connected device is used (see
# apple_pick_device). Xcode 14 has no command for running an app on a device, so scripts/ios-device.ts does it through
# native-run's device library: it installs the app, launches it under the device's debugserver with the test environment,
# and the command-line arguments. Xcode's lldb then takes over the launched process, and is how the run
# resumes it, sees it exit, stops it, and reads the files it writes in its data container, by evaluating Foundation calls
# inside it while it is paused.
#
# iOS starts an app in the root directory whatever working directory debugserver is given, so the run moves the app into
# its data container, by calling chdir in it before the core is created, and gives the settings, vault and log directory as paths relative to it.
#
# A device runs one copy of the app at a time, so a scenario claims the device under a lock for as long as it runs.

IOS_DEVICE_SCRIPTS_DIR="$PHOTOSPHERE_SMOKE_REPO_ROOT/apps/photosphere/scripts"
source "$IOS_DEVICE_SCRIPTS_DIR/lib/apple-common.sh"

#
# Prints how many devices scenarios can run on at once. The run uses one device, and a device runs one copy of the app.
#
photosphere_platform_device_limit() {
    echo 1
}

# The app's bundle identifier.
IOS_DEVICE_BUNDLE_ID="au.com.codecapers.photosphere.ziggy"

# Seconds a scenario waits for the device to be free, and for lldb to answer.
IOS_DEVICE_CLAIM_TIMEOUT_SECONDS=1800
IOS_DEVICE_LLDB_TIMEOUT_SECONDS=120

# The descriptor lldb's commands are written to, and the lock directory this scenario holds.
IOS_DEVICE_LLDB_FD=""
IOS_DEVICE_LOCK_DIR=""

#
# Runs the device helper.
#
photosphere_ios_device_helper() {
    node "$IOS_DEVICE_SCRIPTS_DIR/ios-device.ts" "$@"
}

#
# Claims the device for this scenario, waiting while another scenario holds it, and does nothing when this scenario already holds it.
# The lock is a directory, made atomically by mkdir, holding the process id of the scenario that made it, so a lock left by a
# scenario that was killed, or that has ended, is taken over. The scenario never lets go: its shell ending is what frees the device.
#
photosphere_ios_device_claim() {
    if [ -n "$IOS_DEVICE_LOCK_DIR" ]; then
        return 0
    fi
    local udid="$1"
    local lock_dir="${TMPDIR:-/tmp}/photosphere-ios-device-$udid.lock"
    local waited=0
    local owner
    while ! mkdir "$lock_dir" 2>/dev/null; do
        owner="$(cat "$lock_dir/owner" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "Taking over the lock on $udid from scenario process $owner, which has gone." >&2
            rm -f "$lock_dir/owner"
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        if [ "$waited" -ge "$IOS_DEVICE_CLAIM_TIMEOUT_SECONDS" ]; then
            echo "The device $udid was not free within ${IOS_DEVICE_CLAIM_TIMEOUT_SECONDS}s." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "$$" > "$lock_dir/owner"
    IOS_DEVICE_LOCK_DIR="$lock_dir"
}

#
# Waits until a file exists and is not empty, while a process is alive. Usage: photosphere_ios_device_wait_file <file> <pid> <what>
#
photosphere_ios_device_wait_file() {
    local file="$1"
    local pid="$2"
    local what="$3"
    local waited=0
    while [ ! -s "$file" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "$what exited before it was ready." >&2
            return 1
        fi
        if [ "$waited" -ge 1200 ]; then
            echo "$what was not ready within 120s." >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Prints how many lines of lldb's output match a pattern.
#
photosphere_ios_device_lldb_count() {
    local test_dir="$1"
    local pattern="$2"
    grep -c -E "$pattern" "$test_dir/lldb.log" 2>/dev/null || true
}

#
# Waits until more lines of lldb's output match a pattern than did before. Usage: photosphere_ios_device_lldb_wait <test_dir>
# <pattern> <count before>
#
photosphere_ios_device_lldb_wait() {
    local test_dir="$1"
    local pattern="$2"
    local before="$3"
    local waited=0
    while [ "$(photosphere_ios_device_lldb_count "$test_dir" "$pattern")" -le "$before" ]; do
        if [ "$waited" -ge "$((IOS_DEVICE_LLDB_TIMEOUT_SECONDS * 10))" ]; then
            echo "lldb did not print '$pattern' within ${IOS_DEVICE_LLDB_TIMEOUT_SECONDS}s. Its output ends:" >&2
            tail -n 30 "$test_dir/lldb.log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Sends lldb one command.
#
photosphere_ios_device_lldb() {
    printf '%s\n' "$1" >&"$IOS_DEVICE_LLDB_FD"
}

#
# Whether the app has exited, which lldb reports.
#
photosphere_ios_device_exited() {
    [ "$(photosphere_ios_device_lldb_count "$1" '^Process [0-9]+ exited')" -gt 0 ]
}

#
# Pauses the app, so lldb can evaluate expressions in it.
#
photosphere_ios_device_pause() {
    local test_dir="$1"
    local before
    before="$(photosphere_ios_device_lldb_count "$test_dir" '^Process [0-9]+ stopped')"
    photosphere_ios_device_lldb "process interrupt"
    photosphere_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ stopped' "$before"
}

#
# Resumes the paused app.
#
photosphere_ios_device_resume() {
    local test_dir="$1"
    local before
    before="$(photosphere_ios_device_lldb_count "$test_dir" '^Process [0-9]+ resuming')"
    photosphere_ios_device_lldb "continue"
    photosphere_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ resuming' "$before"
}

#
# Evaluates an Objective-C expression giving an NSString in the paused app, and prints the string, or (null) for nil.
# The value is wrapped in markers numbered for this evaluation, by how many expressions lldb has echoed before it, which
# holds across the subshells callers read the value in. The number is passed as a format argument, so lldb's echo
# of the command never contains the finished marker.
#
photosphere_ios_device_evaluate() {
    local test_dir="$1"
    local expression="$2"
    local mark=$((100001 + $(photosphere_ios_device_lldb_count "$test_dir" "ZIGGYBEGIN%d")))
    local errors_before
    errors_before="$(photosphere_ios_device_lldb_count "$test_dir" '^error: ')"
    photosphere_ios_device_lldb "expression -l objc -O -- [NSString stringWithFormat:@\"ZIGGYBEGIN%d:%@:ZIGGYEND%d\", $mark, $expression, $mark]"
    local waited=0
    while ! grep -q "ZIGGYEND$mark" "$test_dir/lldb.log"; do
        if [ "$(photosphere_ios_device_lldb_count "$test_dir" '^error: ')" -gt "$errors_before" ] || [ "$waited" -ge "$((IOS_DEVICE_LLDB_TIMEOUT_SECONDS * 10))" ]; then
            echo "lldb could not evaluate $expression. Its output ends:" >&2
            tail -n 30 "$test_dir/lldb.log" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    sed -n "s/.*ZIGGYBEGIN$mark:\(.*\):ZIGGYEND$mark.*/\1/p" "$test_dir/lldb.log"
}

#
# Prints the app's data container on the device.
#
photosphere_ios_device_container() {
    jq -r '.container' "$1/launch.json"
}

#
# Takes the lock that keeps one use of lldb at a time. The log pump pauses the app to read its log, as reading the control port does,
# and a second pause or evaluation in the middle of the first would be answered out of order. The lock is a directory, made atomically
# by mkdir. Usage: photosphere_ios_device_lock <test_dir>
#
photosphere_ios_device_lock() {
    local waited=0
    while ! mkdir "$1/lldb.lock" 2>/dev/null; do
        if [ "$waited" -ge "$((IOS_DEVICE_LLDB_TIMEOUT_SECONDS * 10))" ]; then
            echo "The lldb lock in $1 was not free within ${IOS_DEVICE_LLDB_TIMEOUT_SECONDS}s." >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

#
# Lets go of the lock. Usage: photosphere_ios_device_unlock <test_dir>
#
photosphere_ios_device_unlock() {
    rmdir "$1/lldb.lock"
}

#
# Prints the directory the core writes its log to, relative to the app's data container. The container outlives the app, so each
# scenario gets a name of its own, as the port file does.
#
photosphere_ios_device_scenario_dir() {
    printf 'Library/photosphere-smoke/%s\n' "$(basename "$1")"
}

photosphere_platform_prepare() {
    local run_dir="$1"
    apple_require_tool node jq xcrun
    bash "$IOS_DEVICE_SCRIPTS_DIR/build-ios.sh" --sdk device --arch arm64 --configuration Release --native-dir "$run_dir/test-native" --build-dir "$run_dir/test-build" || return 1
}

#
# Starts the app for one scenario, with --remote-control and the address of the scenario's remote control server, which it starts
# first. The device stays claimed until the scenario's shell ends, so a restart finds the same install and data. The settings,
# vault and logs are in a directory of the app's data container named for the scenario, given to the app as paths relative to the
# container, which the run makes the app's working directory before the core is created. Installing the app again keeps its data, so
# keep-data needs nothing more. Usage: photosphere_platform_start <test_dir> [keep-data]
#
photosphere_platform_start() {
    local test_dir="$1"
    local app="$PHOTOSPHERE_SMOKE_RUN_DIR/test-build/Build/Products/Release-iphoneos/Photosphere.app"
    local udid
    udid="$(apple_pick_device)" || return 1
    photosphere_ios_device_claim "$udid" || return 1
    mkdir -p "$test_dir"
    # Files an earlier start in this directory left would be taken for this start's.
    rm -f "$test_dir/launch.json"
    : > "$test_dir/app.log"
    photosphere_start_remote_control_server "$test_dir" || return 1

    # Installing replaces any installed copy and ends a copy that is running.
    photosphere_ios_device_helper install "$udid" "$IOS_DEVICE_BUNDLE_ID" "$app" || return 1

    local scenario_dir
    scenario_dir="$(photosphere_ios_device_scenario_dir "$test_dir")"
    local news_environment=()
    if [ -n "${PHOTOSPHERE_NEWS_URL:-}" ]; then
        news_environment=("PHOTOSPHERE_NEWS_URL=$PHOTOSPHERE_NEWS_URL")
    fi
    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$test_dir/launch.log" node "$IOS_DEVICE_SCRIPTS_DIR/ios-device.ts" launch \
        "$udid" "$IOS_DEVICE_BUNDLE_ID" "$test_dir/launch.json" \
        PHOTOSPHERE_TEST_MODE=1 \
        "PHOTOSPHERE_CONFIG_DIR=$scenario_dir/config" \
        "PHOTOSPHERE_VAULT_DIR=$scenario_dir/vault" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
        "PHOTOSPHERE_LOG_DIR=$scenario_dir" \
        "${news_environment[@]+"${news_environment[@]}"}" -- --remote-control "$PHOTOSPHERE_REMOTE_CONTROL") || return 1
    echo "$pgid" > "$test_dir/launch.pgid"
    photosphere_ios_device_wait_file "$test_dir/launch.json" "$pid" "The device helper's launch" || {
        cat "$test_dir/launch.log" >&2
        return 1
    }

    mkfifo "$test_dir/lldb.fifo" || return 1
    # A fixed descriptor, because the bash MacOS ships (3.2) has no {name} form for choosing a free one.
    exec 8<>"$test_dir/lldb.fifo" || return 1
    IOS_DEVICE_LLDB_FD=8
    read -r pid pgid < <(launch_in_process_group "$test_dir/lldb.log" bash -c 'exec xcrun lldb < "$1"' lldb "$test_dir/lldb.fifo") || return 1
    echo "$pgid" > "$test_dir/lldb.pgid"
    photosphere_ios_device_lldb "settings set plugin.process.gdb-remote.packet-timeout 60"
    photosphere_ios_device_lldb "platform select remote-ios"
    photosphere_ios_device_lldb "target create \"$app/Photosphere\""
    photosphere_ios_device_lldb "process connect connect://127.0.0.1:$(jq -r '.port' "$test_dir/launch.json")"
    photosphere_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ stopped' 0 || return 1
    # A write to a closed socket raises SIGPIPE, which the app handles as an error. It must not pause the app in lldb.
    photosphere_ios_device_lldb "process handle SIGPIPE --notify false --pass true --stop false"

    # The process stops at its first instruction, before Foundation is loaded, when lldb could not evaluate a Foundation
    # call. It is run on to where the native app creates the core, by which point Foundation is loaded, and Foundation's
    # declarations are imported there, so the expressions that read files compile with their real method signatures.
    local stops_before
    stops_before="$(photosphere_ios_device_lldb_count "$test_dir" 'stop reason = breakpoint')"
    photosphere_ios_device_lldb "breakpoint set --name ziggy_create"
    photosphere_ios_device_lldb "continue"
    photosphere_ios_device_lldb_wait "$test_dir" 'stop reason = breakpoint' "$stops_before" || return 1
    photosphere_ios_device_lldb "breakpoint delete --force"
    photosphere_ios_device_lldb "expression -l objc -- @import Foundation"
    photosphere_ios_device_evaluate "$test_dir" '@"Foundation is ready"' > /dev/null || return 1
    photosphere_ios_device_evaluate "$test_dir" "(int)chdir(\"$(photosphere_ios_device_container "$test_dir")\") == 0 ? @\"moved\" : nil" | grep -q "^moved$" || {
        echo "The app could not move into its data container." >&2
        return 1
    }

    photosphere_ios_device_resume "$test_dir" || return 1

    # The scenario reads app.log, and the core writes its log to a file in the container, so a loop copies the file into app.log.
    read -r pid pgid < <(launch_in_process_group "$test_dir/log-pump.log" photosphere_ios_device_pump_log "$test_dir") || return 1
    echo "$pgid" > "$test_dir/log-pump.pgid"
}

#
# Copies the core's log from the container into app.log, until the app exits or the loop is stopped. Each round pauses the app, finds
# the main log file in the log directory (the errors log beside it is left out), reads the bytes added since the last round, in pieces
# of at most 200000 bytes, with each piece carried as base64, and lets the app run on. Run through launch_in_process_group, so the
# lldb descriptor is the one the start opened. Usage: photosphere_ios_device_pump_log <test_dir>
#
photosphere_ios_device_pump_log() {
    local test_dir="$1"
    local logs_dir
    logs_dir="$(photosphere_ios_device_container "$test_dir")/$(photosphere_ios_device_scenario_dir "$test_dir")/logs"
    local log_name=""
    local offset=0
    local length listing contents
    while ! photosphere_ios_device_exited "$test_dir"; do
        photosphere_ios_device_lock "$test_dir" || return 1
        photosphere_ios_device_pause "$test_dir" || {
            photosphere_ios_device_unlock "$test_dir"
            return 1
        }
        if [ -z "$log_name" ]; then
            listing="$(photosphere_ios_device_evaluate "$test_dir" "[[[NSFileManager defaultManager] contentsOfDirectoryAtPath:@\"$logs_dir\" error:nil] componentsJoinedByString:@\"|\"]")" || {
                photosphere_ios_device_unlock "$test_dir"
                return 1
            }
            log_name="$(printf '%s\n' "$listing" | tr '|' '\n' | grep -E '^photosphere-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.log$' | head -n 1 || true)"
        fi
        if [ -n "$log_name" ]; then
            length="$(photosphere_ios_device_evaluate "$test_dir" "[@([[NSData dataWithContentsOfFile:@\"$logs_dir/$log_name\"] length]) stringValue]")" || {
                photosphere_ios_device_unlock "$test_dir"
                return 1
            }
            if [ "$length" -gt "$((offset + 200000))" ]; then
                length=$((offset + 200000))
            fi
            if [ "$length" -gt "$offset" ]; then
                contents="$(photosphere_ios_device_evaluate "$test_dir" "[[[NSData dataWithContentsOfFile:@\"$logs_dir/$log_name\"] subdataWithRange:NSMakeRange($offset, $((length - offset)))] base64EncodedStringWithOptions:0]")" || {
                    photosphere_ios_device_unlock "$test_dir"
                    return 1
                }
                printf '%s' "$contents" | base64 -D >> "$test_dir/app.log" || {
                    photosphere_ios_device_unlock "$test_dir"
                    return 1
                }
                offset="$length"
            fi
        fi
        photosphere_ios_device_resume "$test_dir" || {
            photosphere_ios_device_unlock "$test_dir"
            return 1
        }
        photosphere_ios_device_unlock "$test_dir"
        sleep 0.5
    done
}

#
# Stops the app, the log loop, lldb and the helpers. The device stays claimed until the scenario's shell ends, so a restart finds the
# same install and data. Usage: photosphere_platform_stop <test_dir>
#
photosphere_platform_stop() {
    local test_dir="$1"
    # The loop goes first, so it is not in the middle of reading the log when lldb is told to kill the app.
    if [ -s "$test_dir/log-pump.pgid" ]; then
        kill_process_group "$(cat "$test_dir/log-pump.pgid")" || true
        : > "$test_dir/log-pump.pgid"
    fi
    if [ -n "$IOS_DEVICE_LLDB_FD" ]; then
        if ! photosphere_ios_device_exited "$test_dir"; then
            photosphere_ios_device_lldb "process kill"
        fi
        photosphere_ios_device_lldb "quit"
    fi
    local name
    for name in lldb launch; do
        if [ -s "$test_dir/$name.pgid" ]; then
            kill_process_group "$(cat "$test_dir/$name.pgid")" || true
            : > "$test_dir/$name.pgid"
        fi
    done
    if [ -n "$IOS_DEVICE_LLDB_FD" ]; then
        exec 8>&-
        IOS_DEVICE_LLDB_FD=""
    fi
    rm -f "$test_dir/lldb.fifo"
    if [ -d "$test_dir/lldb.lock" ]; then
        rmdir "$test_dir/lldb.lock"
    fi
}

#
# Waits for the app to end. Usage: photosphere_platform_wait_exit <test_dir> <seconds>
#
photosphere_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local waited=0
    while ! photosphere_ios_device_exited "$test_dir"; do
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
    local test_dir="$1"
    [ -s "$test_dir/launch.json" ] && ! photosphere_ios_device_exited "$test_dir"
}

#
# Clears what the app has stored. Every scenario's settings, vault and logs are in a directory of the app's container named for the
# scenario, and a scenario's start installs the app over the old one without touching the container, so a scenario reads only
# directories nothing else has written to. The vault is a file in that directory (the test mode selects the plaintext vault), so the
# keychain holds nothing to clear. There is nothing for a reset to remove, and a device has no command that removes the container
# without uninstalling the app, so this does nothing.
#
photosphere_platform_reset_app_state() {
    return 0
}

#
# How a connected iPhone or iPad reaches this host's servers is not worked out yet, so these two stop the scenario with a message and
# do not guess an address.
#
ios_host_address() {
    photosphere_ios_not_available ios_host_address
}

ios_expose_host_port() {
    photosphere_ios_not_available ios_expose_host_port
}

#
# How a connected iPhone or iPad's storage and settings are reached from the host is not worked out yet (the app's data container is
# read and written only through lldb), so these stop the scenario with a message and do not guess.
#
ios_app_path() {
    photosphere_ios_not_available ios_app_path
}

ios_seed_database() {
    photosphere_ios_not_available ios_seed_database
}

ios_fetch_database() {
    photosphere_ios_not_available ios_fetch_database
}

ios_seed_databases_config() {
    photosphere_ios_not_available ios_seed_databases_config
}

ios_read_databases_config() {
    photosphere_ios_not_available ios_read_databases_config
}

ios_seed_sync_config() {
    photosphere_ios_not_available ios_seed_sync_config
}

ios_reset_path() {
    photosphere_ios_not_available ios_reset_path
}

ios_wait_for_file() {
    photosphere_ios_not_available ios_wait_for_file
}

ios_grant_media_permission() {
    photosphere_ios_not_available ios_grant_media_permission
}

ios_refuse_media_permission() {
    photosphere_ios_not_available ios_refuse_media_permission
}

ios_background_work_running() {
    photosphere_ios_not_available ios_background_work_running
}

ios_wait_for_background_service_gone() {
    photosphere_ios_not_available ios_wait_for_background_service_gone
}

ios_grant_notification_permission() {
    photosphere_ios_not_available ios_grant_notification_permission
}

ios_config_file_path() {
    photosphere_ios_not_available ios_config_file_path
}

ios_put_config_file() {
    photosphere_ios_not_available ios_put_config_file
}

ios_read_config_file() {
    photosphere_ios_not_available ios_read_config_file
}

ios_config_file_exists() {
    photosphere_ios_not_available ios_config_file_exists
}

ios_damage_vault() {
    photosphere_ios_not_available ios_damage_vault
}

ios_path_exists() {
    photosphere_ios_not_available ios_path_exists
}

#
# How a connected iPhone or iPad's system log, where the background work reports its passes, is read from the host is not worked out
# yet, so these stop the scenario with a message and do not guess.
#
ios_background_work_running() {
    photosphere_ios_not_available ios_background_work_running
}

ios_background_log() {
    photosphere_ios_not_available ios_background_log
}

ios_clear_background_log() {
    photosphere_ios_not_available ios_clear_background_log
}

ios_dump_background_diagnostics() {
    photosphere_ios_not_available ios_dump_background_diagnostics
}

#
# Makes the next download end as the user cancelling it. A phone hands a download to the system share sheet, which a test cannot tap,
# so the sheet's outcome is staged as cancelled through the page. Usage: ios_cancel_next_download <port>
#
ios_cancel_next_download() {
    send_command "$1" stage-export '{"exportOutcome":"cancelled"}'
}
