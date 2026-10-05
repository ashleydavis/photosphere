#!/usr/bin/env bash

# Shared by the MacOS and iOS scripts of the Ziggy example. It is sourced, never run. See apple-common.md.

APPLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_EXAMPLE_DIR="$(cd "$APPLE_LIB_DIR/../.." && pwd)"
APPLE_REPO_ROOT="$(cd "$APPLE_EXAMPLE_DIR/../.." && pwd)"

# Prints an error and stops the calling script.
apple_fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Stops the calling script unless it is running on MacOS.
apple_require_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        apple_fail "this script builds with Xcode, so it runs on MacOS only. This is $(uname -s)."
    fi
}

# Stops the calling script unless every named command is on the PATH. Usage: apple_require_tool <command>...
apple_require_tool() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            apple_fail "'$tool' is not on the PATH. Run the script through mise (mise exec -- ...) so the pinned tools are used, and install jq and Xcode's command line tools if they are missing."
        fi
    done
}

# Stops the calling script unless xcodebuild works.
apple_require_xcode() {
    apple_require_tool xcodebuild xcrun
    if ! xcodebuild -version > /dev/null 2>&1; then
        apple_fail "xcodebuild does not work. Install Xcode and select it with xcode-select."
    fi
}

# Prints the version in apps/ziggy-example/package.json.
apple_package_version() {
    apple_require_tool jq
    jq -r '.version' "$APPLE_EXAMPLE_DIR/package.json"
}

# Prints the architecture of this Mac in the names Xcode uses: arm64 or x86_64.
apple_host_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        arm64|x86_64)
            printf '%s\n' "$machine"
            ;;
        *)
            apple_fail "unknown Mac architecture '$machine'."
            ;;
    esac
}

# Prints Zig's name for an Xcode architecture name. Usage: apple_zig_arch <arm64|x86_64>
apple_zig_arch() {
    case "$1" in
        arm64)
            printf 'aarch64\n'
            ;;
        x86_64)
            printf 'x86_64\n'
            ;;
        *)
            apple_fail "unsupported architecture '$1'. Use arm64 or x86_64."
            ;;
    esac
}

# Bundles the example's page and builds the Zig static library, which embeds the page, so an Xcode build has everything it links.
# <native_dir> gets lib/libziggy_example.a and include/ziggy.h.
# Usage: apple_sync_native <zig_target> <native_dir> <yes|no test hooks> <zig optimize mode>
apple_sync_native() {
    local zig_target="$1"
    local native_dir="$2"
    local test_hooks="$3"
    local optimize="$4"
    apple_require_tool bun zig rsync
    echo "Bundling the page..."
    (cd "$APPLE_EXAMPLE_DIR" && bun run bundle:ui) || apple_fail "bundling the page failed."
    echo "Building the Zig library for $zig_target (optimize $optimize, test hooks $test_hooks)..."
    if [ "$test_hooks" = "yes" ]; then
        (cd "$APPLE_REPO_ROOT/apps/ziggy-example/core" && zig build -Dtarget="$zig_target" -Doptimize="$optimize" -Dtest-hooks=true -p "$native_dir") || apple_fail "the Zig build failed."
    else
        (cd "$APPLE_REPO_ROOT/apps/ziggy-example/core" && zig build -Dtarget="$zig_target" -Doptimize="$optimize" -p "$native_dir") || apple_fail "the Zig build failed."
    fi
}

# Prints the identifier of the iOS simulator to use, booting it if it is not running. It never creates or deletes a
# simulator. The environment variable ZIGGY_IOS_SIMULATOR (a name or an identifier) names one. Without it, a simulator that
# is already running is used, and failing that the first available iPhone.
apple_pick_simulator() {
    apple_require_tool xcrun jq
    local listing wanted udid state
    listing="$(xcrun simctl list devices available -j)" || apple_fail "xcrun simctl list failed."
    wanted="${ZIGGY_IOS_SIMULATOR:-}"
    if [ -n "$wanted" ]; then
        udid="$(printf '%s' "$listing" | jq -r --arg wanted "$wanted" '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.name == $wanted or .udid == $wanted)] | first | .udid // empty')"
        if [ -z "$udid" ]; then
            apple_fail "there is no available iOS simulator named or identified '$wanted'. List them with: xcrun simctl list devices available"
        fi
    else
        udid="$(printf '%s' "$listing" | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.state == "Booted")] | first | .udid // empty')"
        if [ -z "$udid" ]; then
            udid="$(printf '%s' "$listing" | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.name | startswith("iPhone"))] | first | .udid // empty')"
        fi
        if [ -z "$udid" ]; then
            apple_fail "there is no available iPhone simulator. Install one in Xcode (Settings, Platforms) or set ZIGGY_IOS_SIMULATOR."
        fi
    fi
    state="$(printf '%s' "$listing" | jq -r --arg udid "$udid" '[.devices[][] | select(.udid == $udid)] | first | .state')"
    if [ "$state" != "Booted" ]; then
        xcrun simctl bootstatus "$udid" -b >&2 || apple_fail "could not boot the simulator $udid."
    fi
    printf '%s\n' "$udid"
}
