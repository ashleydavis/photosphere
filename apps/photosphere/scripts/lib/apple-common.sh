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

# Bundles Photosphere's page and builds the Zig static library, which embeds the page, so an Xcode build has everything it links.
# <native_dir> gets lib/libphotosphere.a and include/ziggy.h.
# Usage: apple_sync_native <zig_target> <native_dir> <zig optimize mode> <yes|no minify the page>
apple_sync_native() {
    local zig_target="$1"
    local native_dir="$2"
    local optimize="$3"
    local minify="$4"
    local bundle_arguments=()
    if [ "$minify" = "yes" ]; then
        bundle_arguments=(--minify)
    fi
    apple_require_tool bun zig rsync xcrun
    # The page is bundled into a directory of this build's own and embedded from there, so a build of another platform running at
    # the same moment cannot replace it mid-build. Removed when the script exits.
    echo "Bundling the page..."
    local frontend_dir
    frontend_dir="$(cd "$APPLE_APP_DIR/../photosphere-frontend" && pwd)"
    APPLE_PAGE_DIR="$(mktemp -d "$frontend_dir/page.XXXXXX")"
    trap 'find "$APPLE_PAGE_DIR" -type f -delete; find "$APPLE_PAGE_DIR" -depth -type d -empty -delete' EXIT
    (cd "$APPLE_APP_DIR" && bun run bundle:ui --out-dir "$APPLE_PAGE_DIR" "${bundle_arguments[@]+"${bundle_arguments[@]}"}") || apple_fail "bundling the page failed."
    echo "Building the Zig library for $zig_target (optimize $optimize)..."
    (cd "$APPLE_REPO_ROOT" && zig build photosphere-backend -Dtarget="$zig_target" -Doptimize="$optimize" "-Dui-directory=apps/photosphere-frontend/$(basename "$APPLE_PAGE_DIR")" -p "$native_dir") || apple_fail "the Zig build failed."
    # A workaround for a bug in Zig 0.16.0, which is the pinned version. Its archive writer puts the contents of a long-named
    # member at an offset that is not a multiple of 8, and Xcode 26's linker refuses such an archive with "ld: 64-bit mach-o
    # member not 8-byte aligned". The fix is on Zig's master (ziglang/zig issue 35280) and will not reach 0.16.x. Writing the
    # archive again with libtool straight from Zig's archive does not work: libtool warns about the same member and leaves its
    # symbols out, so the link then fails with undefined _ziggy_* symbols. So the members are taken out of the archive as files,
    # and libtool writes a new archive from those, which puts every member at an aligned offset.
    # Xcode links only libphotosphere.a, and a Zig static library does not hold the static libraries it links (the AWS SDK for C, aws-lc,
    # the media libraries), which the build installs under lib/dependencies, so their members go into the new archive too. One archive
    # can hold several members with the same name (an Apple archive keeps only the file's base name, and FFmpeg has several 4xm.o,
    # aacdec.o and others), so ar x, which writes each under its name, keeps only the last of them.
    # Taking the members out one at a time took 16 minutes on a MacOS runner, because FFmpeg has thousands and every zig ar call reads
    # the whole archive again. So each archive is read a fixed number of times: one ar x takes out every member, which is right for
    # every name that appears once, and then, for each instance number a duplicated name reaches, one zig ar xN takes that instance
    # of all such names into a directory of its own (instance 1 as well, since ar x kept the last one). The members are then renamed
    # to numbered files in archive order, so libtool writes them in that order and with no two of the same name.
    echo "Aligning the members of the Zig library and adding its dependencies..."
    local library="$native_dir/lib/libphotosphere.a"
    local members_dir
    members_dir="$(mktemp -d "$native_dir/members.XXXXXX")" || apple_fail "could not make a directory for the library's members."
    local tab
    tab="$(printf '\t')"
    local archive member instance line_number previous source wanted names
    local archive_number=0
    local count=0
    for archive in "$library" "$native_dir"/lib/dependencies/*.a; do
        [ -f "$archive" ] || continue
        archive_number=$((archive_number + 1))
        local archive_dir="$members_dir/archive$archive_number"
        mkdir -p "$archive_dir/members/all" || apple_fail "could not make a directory for the members of $archive."
        names="$(zig ar t "$archive")" || apple_fail "could not list the members of $archive."
        zig ar x "$archive" --output "$archive_dir/members/all" || apple_fail "could not take the members out of $archive."
        # Each line of instances.txt is a member's position in the archive, the instance of its name it is and its name, in archive
        # order. The instance is counted on a copy sorted by name, where the members of one name sit together, so it costs one pass
        # instead of a search of the names before it for every member.
        line_number=0
        while IFS= read -r member; do
            [ -n "$member" ] || continue
            line_number=$((line_number + 1))
            printf '%s\t%s\n' "$line_number" "$member"
        done <<< "$names" > "$archive_dir/numbered.txt"
        LC_ALL=C sort -t "$tab" -k2,2 -k1,1n "$archive_dir/numbered.txt" | {
            previous=""
            instance=0
            while IFS="$tab" read -r line_number member; do
                if [ "$member" = "$previous" ]; then
                    instance=$((instance + 1))
                else
                    instance=1
                    previous="$member"
                fi
                printf '%s\t%s\t%s\n' "$line_number" "$instance" "$member"
            done
        } | LC_ALL=C sort -t "$tab" -k1,1n > "$archive_dir/instances.txt" || apple_fail "could not number the members of $archive."
        # The names with a second instance are exactly the duplicated ones, so they are the names whose first instance is taken too.
        wanted=2
        while :; do
            # Counted apart from the array because bash 3.2 with set -u treats an empty array as unset.
            local duplicated=()
            local duplicated_count=0
            while IFS="$tab" read -r line_number instance member; do
                if [ "$instance" = "$wanted" ]; then
                    duplicated+=("$member")
                    duplicated_count=$((duplicated_count + 1))
                fi
            done < "$archive_dir/instances.txt"
            [ "$duplicated_count" -gt 0 ] || break
            if [ "$wanted" = "2" ]; then
                mkdir -p "$archive_dir/members/1" || apple_fail "could not make a directory for the members of $archive."
                zig ar xPN 1 "$archive" "${duplicated[@]}" --output "$archive_dir/members/1" || apple_fail "could not take the first instance of the duplicated members out of $archive."
            fi
            mkdir -p "$archive_dir/members/$wanted" || apple_fail "could not make a directory for the members of $archive."
            zig ar xPN "$wanted" "$archive" "${duplicated[@]}" --output "$archive_dir/members/$wanted" || apple_fail "could not take instance $wanted of the duplicated members out of $archive."
            wanted=$((wanted + 1))
        done
        # The archives Zig writes record every member's mode as 0 and zig ar x gives the file that mode, so libtool could not read it.
        find "$archive_dir/members" -type f -exec chmod 644 {} + || apple_fail "could not make the members of $archive readable."
        while IFS="$tab" read -r line_number instance member; do
            count=$((count + 1))
            if [ "$instance" != "1" ] || [ -f "$archive_dir/members/1/$member" ]; then
                source="$archive_dir/members/$instance/$member"
            else
                source="$archive_dir/members/all/$member"
            fi
            [ -f "$source" ] || apple_fail "instance $instance of $member was not taken out of $archive."
            mv "$source" "$members_dir/$count.o" || apple_fail "could not move $member out of the extraction directory."
        done < "$archive_dir/instances.txt"
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
