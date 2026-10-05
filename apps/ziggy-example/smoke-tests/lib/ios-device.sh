#!/usr/bin/env bash

# The iOS platform library of the Ziggy example's smoke tests when a device is connected, sourced by ios.sh in place of its
# simulator functions. See common.sh for what it implements.
#
# The app runs on a connected iPhone or iPad: ZIGGY_IOS_DEVICE names one, otherwise the first connected device is used (see
# apple_pick_device). Xcode 14 has no command for running an app on a device, so scripts/ios-device.ts does it through
# native-run's device library: it installs the app, launches it under the device's debugserver with the test environment,
# and forwards the test control port over USB. Xcode's lldb then takes over the launched process, and is how the run
# resumes it, sees it exit, stops it, and reads the files it writes in its data container, by evaluating Foundation calls
# inside it while it is paused.
#
# iOS starts an app in the root directory whatever working directory debugserver is given, so the run moves the app into
# its data container, by calling chdir in it before the core is created, and gives the port file as a path relative to it.
#
# A device runs one copy of the app at a time, so a scenario claims the device under a lock for as long as it runs.

IOS_DEVICE_SCRIPTS_DIR="$ZIGGY_SMOKE_REPO_ROOT/apps/ziggy-example/scripts"
source "$IOS_DEVICE_SCRIPTS_DIR/lib/apple-common.sh"

# The app's bundle identifier.
IOS_DEVICE_BUNDLE_ID="dev.ziggy.example"

#
# Prints where the app writes its control port, relative to its data container. The container outlives the app, so each
# scenario gets a name of its own, and a file an earlier scenario left can never be mistaken for this one's.
#
ziggy_ios_device_port_file() {
    printf 'Library/ziggy-control-port-%s.txt\n' "$(basename "$1")"
}

# Seconds a scenario waits for the device to be free, and for lldb to answer.
IOS_DEVICE_CLAIM_TIMEOUT_SECONDS=1800
IOS_DEVICE_LLDB_TIMEOUT_SECONDS=120

# The descriptor lldb's commands are written to, and the lock directory this scenario holds.
IOS_DEVICE_LLDB_FD=""
IOS_DEVICE_LOCK_DIR=""

#
# Runs the device helper.
#
ziggy_ios_device_helper() {
    node "$IOS_DEVICE_SCRIPTS_DIR/ios-device.ts" "$@"
}

#
# Claims the device for this scenario, waiting while another scenario holds it. The lock is a directory, made atomically by
# mkdir, holding the process id of the scenario that made it, so a lock left by a scenario that was killed is taken over.
#
ziggy_ios_device_claim() {
    local udid="$1"
    local lock_dir="${TMPDIR:-/tmp}/ziggy-ios-device-$udid.lock"
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
# Hands the device back.
#
ziggy_ios_device_release() {
    if [ -n "$IOS_DEVICE_LOCK_DIR" ]; then
        rm -f "$IOS_DEVICE_LOCK_DIR/owner"
        rmdir "$IOS_DEVICE_LOCK_DIR" 2>/dev/null || true
        IOS_DEVICE_LOCK_DIR=""
    fi
}

#
# Waits until a file exists and is not empty, while a process is alive. Usage: ziggy_ios_device_wait_file <file> <pid> <what>
#
ziggy_ios_device_wait_file() {
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
ziggy_ios_device_lldb_count() {
    local test_dir="$1"
    local pattern="$2"
    grep -c -E "$pattern" "$test_dir/lldb.log" 2>/dev/null || true
}

#
# Waits until more lines of lldb's output match a pattern than did before. Usage: ziggy_ios_device_lldb_wait <test_dir>
# <pattern> <count before>
#
ziggy_ios_device_lldb_wait() {
    local test_dir="$1"
    local pattern="$2"
    local before="$3"
    local waited=0
    while [ "$(ziggy_ios_device_lldb_count "$test_dir" "$pattern")" -le "$before" ]; do
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
ziggy_ios_device_lldb() {
    printf '%s\n' "$1" >&"$IOS_DEVICE_LLDB_FD"
}

#
# Whether the app has exited, which lldb reports.
#
ziggy_ios_device_exited() {
    [ "$(ziggy_ios_device_lldb_count "$1" '^Process [0-9]+ exited')" -gt 0 ]
}

#
# Pauses the app, so lldb can evaluate expressions in it.
#
ziggy_ios_device_pause() {
    local test_dir="$1"
    local before
    before="$(ziggy_ios_device_lldb_count "$test_dir" '^Process [0-9]+ stopped')"
    ziggy_ios_device_lldb "process interrupt"
    ziggy_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ stopped' "$before"
}

#
# Resumes the paused app.
#
ziggy_ios_device_resume() {
    local test_dir="$1"
    local before
    before="$(ziggy_ios_device_lldb_count "$test_dir" '^Process [0-9]+ resuming')"
    ziggy_ios_device_lldb "continue"
    ziggy_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ resuming' "$before"
}

#
# Evaluates an Objective-C expression giving an NSString in the paused app, and prints the string, or (null) for nil.
# The value is wrapped in markers numbered for this evaluation, by how many expressions lldb has echoed before it, which
# holds across the subshells callers read the value in. The number is passed as a format argument, so lldb's echo
# of the command never contains the finished marker.
#
ziggy_ios_device_evaluate() {
    local test_dir="$1"
    local expression="$2"
    local mark=$((100001 + $(ziggy_ios_device_lldb_count "$test_dir" "ZIGGYBEGIN%d")))
    local errors_before
    errors_before="$(ziggy_ios_device_lldb_count "$test_dir" '^error: ')"
    ziggy_ios_device_lldb "expression -l objc -O -- [NSString stringWithFormat:@\"ZIGGYBEGIN%d:%@:ZIGGYEND%d\", $mark, $expression, $mark]"
    local waited=0
    while ! grep -q "ZIGGYEND$mark" "$test_dir/lldb.log"; do
        if [ "$(ziggy_ios_device_lldb_count "$test_dir" '^error: ')" -gt "$errors_before" ] || [ "$waited" -ge "$((IOS_DEVICE_LLDB_TIMEOUT_SECONDS * 10))" ]; then
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
ziggy_ios_device_container() {
    jq -r '.container' "$1/launch.json"
}

ziggy_platform_prepare() {
    local run_dir="$1"
    apple_require_tool node jq xcrun
    bash "$IOS_DEVICE_SCRIPTS_DIR/build-ios.sh" --sdk device --arch arm64 --test-hooks --configuration Release --native-dir "$run_dir/test-native" --build-dir "$run_dir/test-build" || return 1
    bash "$IOS_DEVICE_SCRIPTS_DIR/build-ios.sh" --sdk device --arch arm64 --configuration Release --native-dir "$run_dir/release-native" --build-dir "$run_dir/release-build" || return 1
}

ziggy_platform_start() {
    local test_dir="$1"
    local kind="$2"
    local app="$ZIGGY_SMOKE_RUN_DIR/$kind-build/Build/Products/Release-iphoneos/ZiggyExample.app"
    local udid
    udid="$(apple_pick_device)" || return 1
    ziggy_ios_device_claim "$udid" || return 1

    # Installing replaces the other build, which shares the bundle identifier, and ends a copy that is running.
    ziggy_ios_device_helper install "$udid" "$IOS_DEVICE_BUNDLE_ID" "$app" || return 1

    local pid pgid
    read -r pid pgid < <(launch_in_process_group "$test_dir/launch.log" node "$IOS_DEVICE_SCRIPTS_DIR/ios-device.ts" launch \
        "$udid" "$IOS_DEVICE_BUNDLE_ID" "$test_dir/launch.json" \
        ZIGGY_TEST_MODE=1 \
        "ZIGGY_TEST_PORT_FILE=$(ziggy_ios_device_port_file "$test_dir")") || return 1
    echo "$pgid" > "$test_dir/launch.pgid"
    ziggy_ios_device_wait_file "$test_dir/launch.json" "$pid" "The device helper's launch" || {
        cat "$test_dir/launch.log" >&2
        return 1
    }

    mkfifo "$test_dir/lldb.fifo" || return 1
    # A fixed descriptor, because the bash MacOS ships (3.2) has no {name} form for choosing a free one.
    exec 8<>"$test_dir/lldb.fifo" || return 1
    IOS_DEVICE_LLDB_FD=8
    read -r pid pgid < <(launch_in_process_group "$test_dir/lldb.log" bash -c 'exec xcrun lldb < "$1"' lldb "$test_dir/lldb.fifo") || return 1
    echo "$pgid" > "$test_dir/lldb.pgid"
    ziggy_ios_device_lldb "settings set plugin.process.gdb-remote.packet-timeout 60"
    ziggy_ios_device_lldb "platform select remote-ios"
    ziggy_ios_device_lldb "target create \"$app/ZiggyExample\""
    ziggy_ios_device_lldb "process connect connect://127.0.0.1:$(jq -r '.port' "$test_dir/launch.json")"
    ziggy_ios_device_lldb_wait "$test_dir" '^Process [0-9]+ stopped' 0 || return 1
    # A write to a closed socket raises SIGPIPE, which the app handles as an error. It must not pause the app in lldb.
    ziggy_ios_device_lldb "process handle SIGPIPE --notify false --pass true --stop false"

    # The process stops at its first instruction, before Foundation is loaded, when lldb could not evaluate a Foundation
    # call. It is run on to where the shell creates the core, by which point Foundation is loaded, and Foundation's
    # declarations are imported there, so the expressions that read files compile with their real method signatures.
    local stops_before
    stops_before="$(ziggy_ios_device_lldb_count "$test_dir" 'stop reason = breakpoint')"
    ziggy_ios_device_lldb "breakpoint set --name ziggy_create"
    ziggy_ios_device_lldb "continue"
    ziggy_ios_device_lldb_wait "$test_dir" 'stop reason = breakpoint' "$stops_before" || return 1
    ziggy_ios_device_lldb "breakpoint delete --force"
    ziggy_ios_device_lldb "expression -l objc -- @import Foundation"
    ziggy_ios_device_evaluate "$test_dir" '@"Foundation is ready"' > /dev/null || return 1
    ziggy_ios_device_evaluate "$test_dir" "(int)chdir(\"$(ziggy_ios_device_container "$test_dir")\") == 0 ? @\"moved\" : nil" | grep -q "^moved$" || {
        echo "The app could not move into its data container." >&2
        return 1
    }

    ziggy_ios_device_resume "$test_dir" || return 1
    if [ "$kind" = "release" ]; then
        return 0
    fi

    local waited=0
    local device_port=""
    while true; do
        sleep 1
        if ziggy_ios_device_exited "$test_dir"; then
            echo "The app exited before its control connection came up." >&2
            return 1
        fi
        device_port="$(ziggy_ios_device_read_port "$test_dir")" || return 1
        if [ -n "$device_port" ]; then
            break
        fi
        if [ "$waited" -ge 60 ]; then
            echo "The app never wrote its control port." >&2
            return 1
        fi
        waited=$((waited + 1))
    done

    read -r pid pgid < <(launch_in_process_group "$test_dir/forward.log" node "$IOS_DEVICE_SCRIPTS_DIR/ios-device.ts" forward \
        "$udid" "$device_port" "$test_dir/forward.json") || return 1
    echo "$pgid" > "$test_dir/forward.pgid"
    ziggy_ios_device_wait_file "$test_dir/forward.json" "$pid" "The device helper's port forward" || {
        cat "$test_dir/forward.log" >&2
        return 1
    }
    ZIGGY_CONTROL_HOST=127.0.0.1
    ZIGGY_CONTROL_PORT="$(jq -r '.port' "$test_dir/forward.json")"
    export ZIGGY_CONTROL_HOST ZIGGY_CONTROL_PORT
}

#
# Prints the control port the app wrote, and nothing when it has not written one.
#
ziggy_ios_device_read_port() {
    local test_dir="$1"
    local container text
    container="$(ziggy_ios_device_container "$test_dir")"
    ziggy_ios_device_pause "$test_dir" || return 1
    # Encoding 4 is NSUTF8StringEncoding, a name lldb's expression parser does not know.
    text="$(ziggy_ios_device_evaluate "$test_dir" "[[NSString stringWithContentsOfFile:@\"$container/$(ziggy_ios_device_port_file "$test_dir")\" encoding:4 error:nil] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]")" || return 1
    ziggy_ios_device_resume "$test_dir" || return 1
    printf '%s' "$text" | tr -d '\n' | grep -E '^[0-9]+$' || true
}

ziggy_platform_stop() {
    local test_dir="$1"
    if [ -n "$IOS_DEVICE_LLDB_FD" ]; then
        if ! ziggy_ios_device_exited "$test_dir"; then
            ziggy_ios_device_lldb "process kill"
        fi
        ziggy_ios_device_lldb "quit"
    fi
    local name
    for name in forward lldb launch; do
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
    ziggy_ios_device_release
}

#
# Copies the app's private data directory out of its container, file by file, with each file's bytes carried as base64.
# A path that holds no data is a directory.
#
ziggy_platform_data_dir() {
    local test_dir="$1"
    local data_dir="$test_dir/data"
    local device_dir
    device_dir="$(ziggy_ios_device_container "$test_dir")/Library/Application Support/$IOS_DEVICE_BUNDLE_ID"
    mkdir -p "$data_dir"
    ziggy_ios_device_pause "$test_dir" || return 1
    local listing sub_path contents
    listing="$(ziggy_ios_device_evaluate "$test_dir" "[[[NSFileManager defaultManager] subpathsOfDirectoryAtPath:@\"$device_dir\" error:nil] componentsJoinedByString:@\"|\"]")" || return 1
    if [ "$listing" = "(null)" ]; then
        ziggy_ios_device_resume "$test_dir"
        echo "The app's data directory $device_dir does not exist." >&2
        return 1
    fi
    while IFS= read -r sub_path; do
        if [ -z "$sub_path" ]; then
            continue
        fi
        contents="$(ziggy_ios_device_evaluate "$test_dir" "[[NSData dataWithContentsOfFile:@\"$device_dir/$sub_path\"] base64EncodedStringWithOptions:0]")" || return 1
        if [ "$contents" = "(null)" ]; then
            mkdir -p "$data_dir/$sub_path"
        else
            mkdir -p "$(dirname "$data_dir/$sub_path")"
            printf '%s' "$contents" | base64 -D > "$data_dir/$sub_path" || return 1
        fi
    done < <(printf '%s\n' "$listing" | tr '|' '\n')
    ziggy_ios_device_resume "$test_dir" || return 1
    printf '%s\n' "$data_dir"
}

ziggy_platform_wait_exit() {
    local test_dir="$1"
    local seconds="$2"
    local waited=0
    while ! ziggy_ios_device_exited "$test_dir"; do
        if [ "$waited" -ge "$((seconds * 10))" ]; then
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

ziggy_platform_is_running() {
    local test_dir="$1"
    [ -s "$test_dir/launch.json" ] && ! ziggy_ios_device_exited "$test_dir"
}

# The Zig static library carries the core, so it is what scenario 8 searches.
ziggy_platform_artifact_files() {
    local kind="$1"
    printf '%s\n' "$ZIGGY_SMOKE_RUN_DIR/$kind-native/lib/libziggy_example.a"
}

ziggy_platform_has_control_port() {
    local test_dir="$1"
    if ziggy_ios_device_exited "$test_dir"; then
        return 1
    fi
    [ -n "$(ziggy_ios_device_read_port "$test_dir")" ]
}
