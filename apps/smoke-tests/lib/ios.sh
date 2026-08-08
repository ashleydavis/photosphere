#!/bin/bash

# iOS launcher for mobile smoke tests. Sourced by common.sh when PLATFORM=ios.
# Drives an iOS simulator from the host via xcrun simctl. The simulator shares the host loopback,
# so the app reaches the host control bridge on localhost with no port forwarding, and the bridge
# captures the screen with `xcrun simctl io booted screenshot`.
#
# ios_prepare sets things up automatically (like android_prepare): it reuses a booted simulator,
# or boots one, so `bun run test:ios` works without manual setup. Requires macOS with Xcode. Set
# IOS_SIMULATOR_UDID to target a specific simulator.

# Derived-data directory for the xcodebuild output.
IOS_DERIVED_DATA="$SMOKE_TESTS_DIR/tmp/ios-derived-data"

# Path to the built app bundle (populated after ios_build).
IOS_APP_BUNDLE="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/App.app"

# Regex matching a simulator UDID (a UUID) in `xcrun simctl list` output.
IOS_UDID_REGEX='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

#
# Selects a simulator (IOS_SIMULATOR_UDID, else an already-booted one, else the first available
# iPhone), boots it if needed, waits for it to be ready, and shows the Simulator UI. Exports
# IOS_SIMULATOR_UDID so the rest of the run targets the same device.
#
ios_prepare() {
    if ! command -v xcrun >/dev/null 2>&1; then
        log_error "xcrun not found. iOS smoke tests require macOS with Xcode."
        return 1
    fi

    # The `|| true` on each lookup is required: under `set -euo pipefail` (set by run.sh) a `grep` that
    # matches nothing exits non-zero, which pipefail propagates and errexit would turn into a silent
    # abort. On CI no simulator is booted, so the booted lookup finds nothing and must fall through to
    # the available one rather than killing the run.
    local udid="${IOS_SIMULATOR_UDID:-}"
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices booted 2>/dev/null | grep -oE "$IOS_UDID_REGEX" | head -1 || true)
    fi
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices available 2>/dev/null | grep -i 'iPhone' | grep -oE "$IOS_UDID_REGEX" | head -1 || true)
    fi
    if [ -z "$udid" ]; then
        log_error "No iOS simulator found. Create one in Xcode (Window > Devices and Simulators)."
        return 1
    fi
    export IOS_SIMULATOR_UDID="$udid"

    log_info "Using simulator $udid"
    xcrun simctl boot "$udid" 2>/dev/null || true
    # Show the Simulator window (harmless if already open).
    open -a Simulator 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b
    log_info "Simulator booted"
}

#
# iOS has one simulator and no second checkout competing for it, so there is never a foreign build to
# put back. Present so the runner can call the same hook on both platforms.
#
ios_ensure_apk() {
    return 0
}

#
# Prints the device slots the pool should run on, one per line. iOS is always a single slot: the
# simulator ios_prepare already selected and booted. Exists so run.sh can stay platform-neutral and
# drive Android's many devices and iOS's one through the same two hooks.
#
ios_device_slots() {
    echo "${IOS_SIMULATOR_UDID:-}"
}

#
# Binds the calling shell to one simulator. The iOS helpers all read IOS_SIMULATOR_UDID.
# Usage: ios_export_device <udid>
#
ios_export_device() {
    export IOS_SIMULATOR_UDID="$1"
}

#
# Builds the web assets, syncs Capacitor, and builds the app for the simulator.
#
ios_build() {
    log_info "Building iOS app..."
    (cd "$IOS_FRONTEND_DIR" && bun run sync)

    # Build for the concrete booted simulator (not the generic destination) so xcodebuild builds a
    # single arch matching the simulator (x86_64 on Intel hosts, arm64 on Apple Silicon). The bundled
    # native media static libraries (vendor/im) are single-arch per host, so a universal simulator
    # build would fail to link the non-host slice.
    xcodebuild \
        -workspace "$IOS_FRONTEND_DIR/ios/App/App.xcworkspace" \
        -scheme App \
        -sdk iphonesimulator \
        -configuration Debug \
        -derivedDataPath "$IOS_DERIVED_DATA" \
        -destination "id=$IOS_SIMULATOR_UDID" \
        build
}

#
# Installs the built app on the selected simulator.
#
ios_install() {
    if [ ! -d "$IOS_APP_BUNDLE" ]; then
        log_error "App bundle not found at $IOS_APP_BUNDLE (did ios_build run?)"
        return 1
    fi
    log_info "Installing app on simulator..."
    xcrun simctl install "${IOS_SIMULATOR_UDID:-booted}" "$IOS_APP_BUNDLE"
}

#
# Prints the address the simulator uses to reach this host.
#
# The simulator shares the host's network stack, so the host is simply loopback. This is the iOS
# counterpart of android_host_address, so a test needing to point the app at a host-side server (the
# S3 emulator, for one) can ask for the address the same way on either platform. The literal IPv4
# address, never the name: see BRIDGE_HOST in lib/common.sh.
#
ios_host_address() {
    echo "$BRIDGE_HOST"
}

#
# Launches the app in test mode, passing the bridge address via SIMCTL_CHILD_* env vars (which
# arrive in the app's environment without the prefix).
# Usage: ios_launch <port>
#
ios_launch() {
    local port="$1"
    # The literal loopback address, never the name: the bridge listens on 0.0.0.0, which is IPv4
    # only, so an app that resolved "localhost" to ::1 would not reach it. See BRIDGE_HOST in
    # lib/common.sh.
    SIMCTL_CHILD_PHOTOSPHERE_TEST_MODE=1 \
    SIMCTL_CHILD_PHOTOSPHERE_TEST_HOST="$BRIDGE_HOST" \
    SIMCTL_CHILD_PHOTOSPHERE_TEST_PORT="$port" \
    xcrun simctl launch --terminate-running-process "${IOS_SIMULATOR_UDID:-booted}" "$BUNDLE_ID"
}

#
# Terminates the app on the selected simulator.
# Usage: ios_stop <port>
#
ios_stop() {
    xcrun simctl terminate "${IOS_SIMULATOR_UDID:-booted}" "$BUNDLE_ID"
}

#
# Resolves the host path of the installed app's data container on the simulator. The native iOS
# storage root is the app's Documents directory (see JsEnginePlugin.storageRoot), which lives under
# this container, so seeding/reset copy into Documents/. The app must already be installed (the
# container does not exist before install); start_app installs and launches it before any seeding.
#
ios_app_container() {
    xcrun simctl get_app_container "${IOS_SIMULATOR_UDID:-booted}" "$BUNDLE_ID" data 2>/dev/null
}

#
# Seeds a database fixture into the app's Documents directory (the native iOS storage sandbox root
# resolved by JsEnginePlugin.storageRoot / PathSandbox), so the embedded worker can read it via the
# host fs functions. The simulator container is on the host filesystem, so a plain recursive copy is
# enough (no run-as dance like Android). Mirrors android_seed_database's contract: <rel_dest> is
# relative to the storage root.
# Usage: ios_seed_database <host_fixture_dir> <relative_dest_under_documents>
#
ios_seed_database() {
    local host_src="$1"
    local rel_dest="$2"
    local container
    container="$(ios_app_container)"
    if [ -z "$container" ]; then
        log_error "Could not resolve iOS app data container for $BUNDLE_ID (is the app installed?)"
        return 1
    fi
    local dest="$container/Documents/$rel_dest"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    cp -R "$host_src" "$dest"
    log_info "Seeded database fixture '$(basename "$host_src")' into app container at Documents/$rel_dest"
}

#
# Writes the app's databases.toml into its Documents directory, registering the given databases and
# recent-database names. Mirrors android_seed_databases_config's contract: the state goes in from
# outside the app, before it launches, the way a desktop smoke test pre-writes
# ~/.config/photosphere/databases.toml.
#
# Both arguments are JSON: the databases as an array of {name, path} (description optional), the
# recents as an array of names. An omitted recents argument writes an empty recents list.
# Usage: ios_seed_databases_config '<databases json>' ['<recent names json>']
#
ios_seed_databases_config() {
    local databases_json="$1"
    local recent_json="${2:-[]}"
    local container
    container="$(ios_app_container)"
    if [ -z "$container" ]; then
        log_error "Could not resolve iOS app data container for $BUNDLE_ID (is the app installed?)"
        return 1
    fi
    mkdir -p "$container/Documents"
    if ! DATABASES="$databases_json" RECENT="$recent_json" bun "$LIB_DIR/write-databases-config.ts" "$container/Documents/$DATABASES_CONFIG_FILE"; then
        log_error "Could not render the app's database list (see the error above)."
        return 1
    fi
    log_info "Wrote the app's database list to Documents/$DATABASES_CONFIG_FILE"
}

#
# Wipes everything the app has stored on the simulator: its storage sandbox (Documents), the WebKit
# website data the WebView's localStorage lives in (Library), and the simulator keychain holding the
# secrets.
#
# This is what gives a test a deterministic start, and it replaces the app-side reset-config command.
# The app's keychain items are not in its container (they live in the simulator's own keychain), so
# emptying the container is not enough on its own; `simctl keychain reset` is what clears them. Call
# this BEFORE start_app, so nothing can write state back underneath it.
#
#
# Clears the app's stored data once a test has finished with the simulator, so nothing a test wrote
# is still there when the next one starts. The Android counterpart carries the reasoning.
#
# Quiet and unable to fail: it runs after a test's result has been decided, so it must not be able
# to turn a passing test into a failing one. The keychain is left alone, unlike the reset on the way
# in, because resetting it is the part that can fail and a secret left behind is cleared by the next
# test before anything reads it.
#
ios_clean_after_test() {
    local container
    container="$(ios_app_container)"
    if [ -n "$container" ]; then
        rm -rf "$container/Documents/"* "$container/Library/"* "$container/tmp/"* 2>/dev/null || true
    fi
}

ios_reset_app_state() {
    local container
    container="$(ios_app_container)"
    if [ -n "$container" ]; then
        rm -rf "$container/Documents/"* "$container/Library/"* "$container/tmp/"* 2>/dev/null || true
    fi
    if ! xcrun simctl keychain "${IOS_SIMULATOR_UDID:-booted}" reset >/dev/null 2>&1; then
        log_error "Could not reset the simulator keychain; a secret from an earlier test may still be present."
        return 1
    fi
    log_info "Cleared the app's stored data (container, WebKit storage, keychain)"
}

#
# Removes a path under the app's Documents directory (the storage sandbox root), so a test that
# creates fresh state at that path is rerunnable. No-op when the app/container is not present yet.
# Usage: ios_reset_path <relative_path_under_documents>
#
ios_reset_path() {
    local rel="$1"
    local container
    container="$(ios_app_container)"
    if [ -z "$container" ]; then
        return 0
    fi
    rm -rf "$container/Documents/$rel" 2>/dev/null || true
}

#
# Polls the app's Documents directory until the given path exists and is non-empty (for a directory,
# until it lists at least one entry), or the wait times out. Mirrors android_wait_for_file: it lets a
# test observe a background task's effect on device storage (for example a partial-database prefetch
# copying thumbnails into the local replica). Returns 0 once present, non-zero on timeout.
# Usage: ios_wait_for_file <relative_path_under_documents>
#
ios_wait_for_file() {
    local rel="$1"
    local container
    container="$(ios_app_container)"
    local elapsed=0
    while [ "$elapsed" -lt "$DEFAULT_WAIT_TIMEOUT" ]; do
        if [ -n "$container" ] && [ -n "$(ls -A "$container/Documents/$rel" 2>/dev/null)" ]; then
            return 0
        fi
        container="$(ios_app_container)"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

#
# Removes everything a run leaves in the app's container: the databases seeded into its storage
# sandbox (Documents) and whatever the run imported into them. The app stays installed, so the next
# run does not pay for a reinstall.
#
# Without this the seeded fixtures and imported assets accumulate run after run and fill the
# simulator's disk.
#
ios_cleanup() {
    local container
    container="$(ios_app_container)"
    if [ -z "$container" ]; then
        return 0
    fi
    rm -rf "$container/Documents/"* 2>/dev/null || true
    log_info "Cleared the app's data from the simulator"
}
