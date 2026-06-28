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

    local udid="${IOS_SIMULATOR_UDID:-}"
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices booted 2>/dev/null | grep -oE "$IOS_UDID_REGEX" | head -1)
    fi
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices available 2>/dev/null | grep -i 'iPhone' | grep -oE "$IOS_UDID_REGEX" | head -1)
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
# Builds the web assets, syncs Capacitor, and builds the app for the simulator.
#
ios_build() {
    log_info "Building iOS app..."
    (cd "$IOS_FRONTEND_DIR" && bun run sync)
    xcodebuild \
        -workspace "$IOS_FRONTEND_DIR/ios/App/App.xcworkspace" \
        -scheme App \
        -sdk iphonesimulator \
        -configuration Debug \
        -derivedDataPath "$IOS_DERIVED_DATA" \
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
# Launches the app in test mode, passing the bridge address via SIMCTL_CHILD_* env vars (which
# arrive in the app's environment without the prefix).
# Usage: ios_launch <port>
#
ios_launch() {
    local port="$1"
    SIMCTL_CHILD_PHOTOSPHERE_TEST_MODE=1 \
    SIMCTL_CHILD_PHOTOSPHERE_TEST_HOST=localhost \
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
