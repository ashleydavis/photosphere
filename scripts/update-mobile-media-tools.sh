#!/usr/bin/env bash
# Updates the bundled mobile ImageMagick and ffmpeg. Each step is opt-in via a flag, so you can
# update one tool/platform at a time. See docs/updating-mobile-imagemagick-ffmpeg.md for the full
# background.
#
# Note: no third-party binaries/headers are committed. Android ImageMagick is normally pulled from
# downstream by scripts/fetch-mobile-media-tools.sh (bump IM_VERSION there to change versions); the
# --android-so-dir / --android-headers-dir flow here remains only for dropping in a build you made
# yourself, and it writes into the git-ignored jniLibs/cpp-imagemagick that the fetch script owns.
# This script still handles the iOS from-source ImageMagick build and the ffmpeg version bumps; the
# Xcode SPM update is printed as guidance (Xcode owns it).
#
# Examples:
#   scripts/update-mobile-media-tools.sh --imagemagick-version 7.1.1-45 --build-ios
#   scripts/update-mobile-media-tools.sh --android-ffmpeg-version 6.2.0
#   scripts/update-mobile-media-tools.sh --android-so-dir ~/im-android/lib --android-headers-dir ~/im-android/include
#   scripts/update-mobile-media-tools.sh --verify
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IM_BUILD_SCRIPT="$REPO_ROOT/apps/ios-frontend/ios/build-imagemagick.sh"
ANDROID_GRADLE="$REPO_ROOT/apps/android-frontend/android/app/build.gradle"
ANDROID_JNILIBS="$REPO_ROOT/apps/android-frontend/android/app/src/main/jniLibs"
ANDROID_IM_HEADERS="$REPO_ROOT/apps/android-frontend/android/app/src/main/cpp/imagemagick/include"

# Defaults: no flags -> print usage.
IMAGEMAGICK_VERSION=""
BUILD_IOS=0
ANDROID_FFMPEG_VERSION=""
IOS_FFMPEG_VERSION=""
ANDROID_SO_DIR=""
ANDROID_HEADERS_DIR=""
ANDROID_ABIS="arm64-v8a x86_64"
DO_VERIFY=0

usage() {
    cat <<'USAGE'
Update the bundled mobile ImageMagick and ffmpeg. Each step is opt-in via a flag, so you can
update one tool or platform at a time. Full background: docs/updating-mobile-imagemagick-ffmpeg.md

Usage:
  scripts/update-mobile-media-tools.sh [options]   (no options prints this help)

Options:
  --imagemagick-version <tag>     Set the iOS ImageMagick source version (e.g. 7.1.1-45) in build-imagemagick.sh.
  --build-ios                     After setting the version, run the iOS ImageMagick from-source build (macOS only).
  --android-ffmpeg-version <ver>  Bump the Android FFmpegKit Maven version in app/build.gradle (if the dep is present).
  --ios-ffmpeg-version <ver>      Print the steps to update the iOS FFmpegKit Swift Package (Xcode owns resolution).
  --android-so-dir <dir>          Copy <dir>/<abi>/libmagick*.so (+ libc++_shared/libomp if present) into jniLibs/<abi>.
  --android-headers-dir <dir>     Copy new ImageMagick headers from <dir> into cpp/imagemagick/include.
  --abis "<a> <b>"                ABIs to place Android .so for (default: "arm64-v8a x86_64").
  --verify                        Run the unit/compile checks after updating.
  -h, --help                      This help.

Examples:
  # Bump and rebuild iOS ImageMagick from source (on macOS):
  scripts/update-mobile-media-tools.sh --imagemagick-version 7.1.1-45 --build-ios

  # Bump the Android ffmpeg version:
  scripts/update-mobile-media-tools.sh --android-ffmpeg-version 6.2.0

  # Drop in new Android ImageMagick binaries + headers you already extracted:
  scripts/update-mobile-media-tools.sh --android-so-dir ~/im/lib --android-headers-dir ~/im/include

  # Update everything, then run the checks:
  scripts/update-mobile-media-tools.sh --imagemagick-version 7.1.1-45 --build-ios \
    --android-ffmpeg-version 6.2.0 --ios-ffmpeg-version 6.0.1 --verify

Notes:
  - The iOS FFmpegKit (Swift Package) update is not automated: Xcode owns package resolution, so
    --ios-ffmpeg-version only prints the steps.
  - Fetching the Android ImageMagick .so is not automated (upstream layout varies): point
    --android-so-dir / --android-headers-dir at artifacts you have already extracted.
  - After updating, refresh THIRD-PARTY-NOTICES.md, README.md, and the release.yml notices block.
USAGE
}

# Portable in-place regex replace (GNU and BSD/macOS spell `sed -i` differently, so neither is used).
# Usage: edit_in_place <file> <pattern> <replacement>
edit_in_place() {
    local file="$1"
    local pattern="$2"
    local replacement="$3"
    bun "$REPO_ROOT/scripts/replace-in-file.ts" --file "$file" --pattern "$pattern" --replacement "$replacement"
}

log() { printf '\033[0;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33mwarn:\033[0m %s\n' "$1"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

update_imagemagick_version() {
    [ -f "$IM_BUILD_SCRIPT" ] || die "not found: $IM_BUILD_SCRIPT"
    log "Setting iOS ImageMagick version to $IMAGEMAGICK_VERSION in build-imagemagick.sh"
    edit_in_place "$IM_BUILD_SCRIPT" '^IM_VERSION=".*"' 'IM_VERSION="'"$IMAGEMAGICK_VERSION"'"'
    grep -nE '^IM_VERSION=' "$IM_BUILD_SCRIPT"
}

build_ios_imagemagick() {
    command -v xcrun >/dev/null 2>&1 || die "--build-ios needs macOS + Xcode command-line tools (xcrun not found)"
    log "Building iOS ImageMagick from source (device + simulator slices)"
    bash "$IM_BUILD_SCRIPT"
}

update_android_ffmpeg_version() {
    [ -f "$ANDROID_GRADLE" ] || die "not found: $ANDROID_GRADLE"
    if grep -qE "ffmpeg-kit[^:'\"]*:" "$ANDROID_GRADLE"; then
        log "Bumping Android FFmpegKit version to $ANDROID_FFMPEG_VERSION in app/build.gradle"
        edit_in_place "$ANDROID_GRADLE" '(ffmpeg-kit[^:'\''"]*:)[0-9][^'\''"]*' '$1'"$ANDROID_FFMPEG_VERSION"
        grep -nE "ffmpeg-kit" "$ANDROID_GRADLE"
    else
        warn "No ffmpeg-kit dependency found in app/build.gradle. Add it first, e.g.:"
        printf "    implementation 'com.moizhassan.ffmpeg:ffmpeg-kit-16kb:%s'\n" "$ANDROID_FFMPEG_VERSION"
    fi
}

print_ios_ffmpeg_steps() {
    log "iOS FFmpegKit ($IOS_FFMPEG_VERSION): Xcode owns Swift Package resolution. Do one of:"
    cat <<STEPS
  - In Xcode: File > Packages > Update to Latest Package Versions, or open the ffmpeg-kit package
    dependency and set the version/revision to $IOS_FFMPEG_VERSION, then build.
  - Or edit the pinned version in the project's Package.resolved and let Xcode re-resolve on next build.
  Keep the "full" variant (needs the mjpeg encoder for screenshots). FfmpegKitRunner.swift is gated on
  #if canImport(ffmpegkit), so an absent/renamed package silently disables it.
STEPS
}

place_android_so() {
    [ -d "$ANDROID_SO_DIR" ] || die "--android-so-dir not a directory: $ANDROID_SO_DIR"
    for abi in $ANDROID_ABIS; do
        local src="$ANDROID_SO_DIR/$abi"
        local dest="$ANDROID_JNILIBS/$abi"
        if [ ! -d "$src" ]; then
            warn "no $abi dir under $ANDROID_SO_DIR (looked for $src); skipping"
            continue
        fi
        mkdir -p "$dest"
        log "Placing $abi ImageMagick .so into jniLibs/$abi"
        local copied=0
        for name in libmagickcore-7.so libmagickwand-7.so libc++_shared.so libomp.so; do
            if [ -f "$src/$name" ]; then
                cp "$src/$name" "$dest/$name"
                printf "    %s\n" "$name"
                copied=$((copied + 1))
            fi
        done
        [ "$copied" -gt 0 ] || warn "no expected .so files found in $src"
    done
}

place_android_headers() {
    [ -d "$ANDROID_HEADERS_DIR" ] || die "--android-headers-dir not a directory: $ANDROID_HEADERS_DIR"
    log "Copying ImageMagick headers into cpp/imagemagick/include"
    mkdir -p "$ANDROID_IM_HEADERS"
    cp -R "$ANDROID_HEADERS_DIR/." "$ANDROID_IM_HEADERS/"
    warn "Check that MAGICKCORE_QUANTUM_DEPTH in cpp/CMakeLists.txt matches the new library's quantum depth."
}

run_verify() {
    log "Verifying: mobile-worker unit tests + native compile checks"
    ( cd "$REPO_ROOT" && bun run --filter=mobile-worker test )
    ( cd "$REPO_ROOT" && bun run build:and ) || warn "build:and failed or Android toolchain unavailable"
    if command -v xcrun >/dev/null 2>&1; then
        ( cd "$REPO_ROOT" && bun run test:ios:unit ) || warn "test:ios:unit failed (check the simulator destination)"
    else
        warn "Skipping iOS checks (not on macOS)."
    fi
    log "For the real end-to-end proof run: bun run test:and  and  bun run test:ios  (needs vendored binaries + emulator/simulator)."
}

main() {
    if [ "$#" -eq 0 ]; then
        usage
        exit 0
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --imagemagick-version) IMAGEMAGICK_VERSION="$2"; shift 2 ;;
            --build-ios) BUILD_IOS=1; shift ;;
            --android-ffmpeg-version) ANDROID_FFMPEG_VERSION="$2"; shift 2 ;;
            --ios-ffmpeg-version) IOS_FFMPEG_VERSION="$2"; shift 2 ;;
            --android-so-dir) ANDROID_SO_DIR="$2"; shift 2 ;;
            --android-headers-dir) ANDROID_HEADERS_DIR="$2"; shift 2 ;;
            --abis) ANDROID_ABIS="$2"; shift 2 ;;
            --verify) DO_VERIFY=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (use --help)" ;;
        esac
    done

    [ -n "$IMAGEMAGICK_VERSION" ] && update_imagemagick_version
    [ "$BUILD_IOS" -eq 1 ] && build_ios_imagemagick
    [ -n "$ANDROID_FFMPEG_VERSION" ] && update_android_ffmpeg_version
    [ -n "$IOS_FFMPEG_VERSION" ] && print_ios_ffmpeg_steps
    [ -n "$ANDROID_SO_DIR" ] && place_android_so
    [ -n "$ANDROID_HEADERS_DIR" ] && place_android_headers
    [ "$DO_VERIFY" -eq 1 ] && run_verify

    log "Done. Remember to refresh THIRD-PARTY-NOTICES.md, README.md, and the release.yml notices block with the new versions/licences."
}

main "$@"
