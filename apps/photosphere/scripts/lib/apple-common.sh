#!/usr/bin/env bash

# Shared by the MacOS and iOS scripts of Photosphere. It is sourced, never run. See apple-common.md.

APPLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_APP_DIR="$(cd "$APPLE_LIB_DIR/../.." && pwd)"
APPLE_REPO_ROOT="$(cd "$APPLE_APP_DIR/../.." && pwd)"

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
            apple_fail "'$tool' is not on the PATH. Run mise install from the repository root so the pinned tools are used, and install jq and Xcode's command line tools if they are missing."
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

# Prints the version in apps/photosphere/package.json.
apple_package_version() {
    apple_require_tool jq
    jq -r '.version' "$APPLE_APP_DIR/package.json"
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

# Makes the files ImageMagick and FFmpeg need for the Zig target, by the generate-config.sh of each, when they are not there yet. The
# target is named as the sync scripts give it to Zig ("aarch64-ios.14.0", "x86_64-ios.14.0-simulator", "aarch64-macos.11.0"), and the
# generated files are kept by the name without the version. The scripts take the iOS SDK from xcrun, so this runs on a Mac only.
# Usage: apple_generate_media_config <zig_target>
apple_generate_media_config() {
    local zig_target="$1"
    local arch="${zig_target%%-*}"
    local name
    case "$zig_target" in
        *-ios.*-simulator | *-ios-simulator)
            name="$arch-ios-simulator"
            ;;
        *-ios.* | *-ios)
            name="$arch-ios"
            ;;
        *-macos.* | *-macos)
            name="$arch-macos"
            ;;
        *)
            apple_fail "no media library files are made for the Zig target '$zig_target'."
            ;;
    esac
    local library
    for library in imagemagick ffmpeg; do
        local config_dir="$APPLE_REPO_ROOT/packages-zig/media-tools-zig/$library/config/$name"
        if [ ! -d "$config_dir" ]; then
            echo "Making the $library files for $name..."
            bash "$APPLE_REPO_ROOT/packages-zig/media-tools-zig/$library/generate-config.sh" "$name" || apple_fail "making the $library files for $name failed."
        fi
    done
}

# Bundles Photosphere's page and builds the Zig static library, which embeds the page, so an Xcode build has everything it links.
# <native_dir> gets lib/libphotosphere.a and include/ziggy.h.
# Usage: apple_sync_native <zig_target> <native_dir> <yes|no test hooks> <zig optimize mode> <yes|no minify the page>
apple_sync_native() {
    local zig_target="$1"
    local native_dir="$2"
    local test_hooks="$3"
    local optimize="$4"
    local minify="$5"
    local bundle_arguments=()
    if [ "$minify" = "yes" ]; then
        bundle_arguments=(--minify)
    fi
    apple_require_tool bun zig rsync xcrun
    apple_generate_media_config "$zig_target"
    echo "Bundling the page..."
    (cd "$APPLE_APP_DIR" && bun run bundle:ui "${bundle_arguments[@]+"${bundle_arguments[@]}"}") || apple_fail "bundling the page failed."
    echo "Building the Zig library for $zig_target (optimize $optimize, test hooks $test_hooks)..."
    if [ "$test_hooks" = "yes" ]; then
        (cd "$APPLE_REPO_ROOT" && zig build photosphere-backend -Dtarget="$zig_target" -Doptimize="$optimize" -Dtest-hooks=true -p "$native_dir") || apple_fail "the Zig build failed."
    else
        (cd "$APPLE_REPO_ROOT" && zig build photosphere-backend -Dtarget="$zig_target" -Doptimize="$optimize" -p "$native_dir") || apple_fail "the Zig build failed."
    fi
    # A workaround for a bug in Zig 0.16.0, which is the pinned version. Its archive writer puts the contents of a long-named
    # member at an offset that is not a multiple of 8, and Xcode 26's linker refuses such an archive with "ld: 64-bit mach-o
    # member not 8-byte aligned". The fix is on Zig's master (ziglang/zig issue 35280) and will not reach 0.16.x. Writing the
    # archive again with libtool straight from Zig's archive does not work: libtool warns about the same member and leaves its
    # symbols out, so the link then fails with undefined _ziggy_* symbols. So the members are taken out of the archive as files,
    # and libtool writes a new archive from those, which puts every member at an aligned offset.
    # Xcode links only libphotosphere.a, and a Zig static library does not hold the static libraries it links (the AWS SDK for C, aws-lc,
    # the media libraries), which the build installs under lib/dependencies, so their members go into the new archive too. One archive
    # can hold several members with the same name (an Apple archive keeps only the file's base name, and FFmpeg has several 4xm.o,
    # aacdec.o and others), so ar x, which writes each under its name, would keep only the last of them. Each member is taken out on its
    # own into a numbered file instead, as the instance of its name it is (zig ar's N modifier), counted from the names listed before it.
    echo "Aligning the members of the Zig library and adding its dependencies..."
    local library="$native_dir/lib/libphotosphere.a"
    local members_dir
    members_dir="$(mktemp -d "$native_dir/members.XXXXXX")" || apple_fail "could not make a directory for the library's members."
    local archive member instance
    local count=0
    for archive in "$library" "$native_dir"/lib/dependencies/*.a; do
        [ -f "$archive" ] || continue
        local names
        names="$(zig ar t "$archive")" || apple_fail "could not list the members of $archive."
        : > "$members_dir/seen.txt"
        while IFS= read -r member; do
            [ -n "$member" ] || continue
            printf '%s\n' "$member" >> "$members_dir/seen.txt"
            instance="$(grep -cxF -- "$member" "$members_dir/seen.txt")"
            count=$((count + 1))
            # zig ar takes the instance of a name only with x, which writes the member under its name, so into a directory of its own.
            mkdir -p "$members_dir/one" || apple_fail "could not make a directory for a member of $archive."
            zig ar xPN "$instance" "$archive" "$member" --output "$members_dir/one" || apple_fail "could not take $member out of $archive."
            local extracted
            extracted="$(find "$members_dir/one" -type f)"
            [ -n "$extracted" ] || apple_fail "taking $member out of $archive wrote no file."
            mv "$extracted" "$members_dir/$count.o" || apple_fail "could not move $member out of the extraction directory."
            find "$members_dir/one" -depth -mindepth 1 -type d -empty -delete
        done <<< "$names"
    done
    local members=()
    for ((index = 1; index <= count; index++)); do
        members+=("$members_dir/$index.o")
    done
    xcrun libtool -static -o "$library.aligned" "${members[@]}" || apple_fail "libtool could not write the Zig library again."
    mv "$library.aligned" "$library" || apple_fail "could not replace the Zig library with the aligned one."
    find "$members_dir" -type f -delete
    find "$members_dir" -depth -type d -empty -delete
}

# Prints the identifier of the iOS simulator to use, booting it if it is not running. It never creates or deletes a
# simulator. The environment variable PHOTOSPHERE_IOS_SIMULATOR (a name or an identifier) names one. Without it, a simulator that
# is already running is used, and failing that the first available iPhone.
apple_pick_simulator() {
    apple_require_tool xcrun jq
    local listing wanted udid state
    listing="$(xcrun simctl list devices available -j)" || apple_fail "xcrun simctl list failed."
    wanted="${PHOTOSPHERE_IOS_SIMULATOR:-}"
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
            apple_fail "there is no available iPhone simulator. Install one in Xcode (Settings, Platforms) or set PHOTOSPHERE_IOS_SIMULATOR."
        fi
    fi
    state="$(printf '%s' "$listing" | jq -r --arg udid "$udid" '[.devices[][] | select(.udid == $udid)] | first | .state')"
    if [ "$state" != "Booted" ]; then
        xcrun simctl bootstatus "$udid" -b >&2 || apple_fail "could not boot the simulator $udid."
    fi
    printf '%s\n' "$udid"
}

# Prints the Apple development team to sign a device build with. The environment variable PHOTOSPHERE_IOS_TEAM names one.
# Without it, the team of the account signed in to Xcode (Preferences, Accounts) is used, if there is exactly one.
apple_pick_team() {
    local teams count
    if [ -n "${PHOTOSPHERE_IOS_TEAM:-}" ]; then
        printf '%s\n' "$PHOTOSPHERE_IOS_TEAM"
        return
    fi
    teams="$(defaults export com.apple.dt.Xcode - | plutil -extract IDEProvisioningTeams xml1 -o - - 2> /dev/null | grep -A1 '<key>teamID</key>' | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | sort -u)"
    count="$(printf '%s' "$teams" | grep -c . || true)"
    if [ "$count" = "0" ]; then
        apple_fail "Xcode has no signed in account to sign a device build with. Sign in under Xcode, Preferences, Accounts, or set PHOTOSPHERE_IOS_TEAM."
    fi
    if [ "$count" != "1" ]; then
        apple_fail "Xcode has several teams ($(printf '%s' "$teams" | tr '\n' ' ')). Set PHOTOSPHERE_IOS_TEAM to the one to sign with."
    fi
    printf '%s\n' "$teams"
}

# Prints the identifier of the connected iOS device to run on, or nothing when none is connected. The environment variable
# PHOTOSPHERE_IOS_DEVICE names one. Without it, the first connected device is used.
apple_connected_device() {
    apple_require_tool jq
    if [ -n "${PHOTOSPHERE_IOS_DEVICE:-}" ]; then
        printf '%s\n' "$PHOTOSPHERE_IOS_DEVICE"
        return
    fi
    "$APPLE_REPO_ROOT/node_modules/.bin/native-run" ios --list --json | jq -r '.devices | first | .id // empty' || apple_fail "native-run could not list the iOS devices."
}

# Prints the identifier of the connected iOS device to run on, as apple_connected_device chooses it, and fails when none
# is connected.
apple_pick_device() {
    local udid
    udid="$(apple_connected_device)" || exit 1
    if [ -z "$udid" ]; then
        apple_fail "there is no iOS device connected. Plug one in, unlock it and trust this Mac."
    fi
    printf '%s\n' "$udid"
}
