#!/usr/bin/env bash
# Pulls the native ImageMagick libraries and headers from downstream and builds what is needed,
# placing everything in git-ignored locations. Nothing produced here is copied by hand or committed:
# the repo carries only Photosphere's own shim/build source (run_magick.c, CMakeLists.txt, the
# runners) and this script; the third-party ImageMagick artifacts are fetched/built on demand.
#
# Android: downloads the prebuilt MolotovCherry/Android-ImageMagick7 .so from its GitHub release,
# downloads the matching ImageMagick source, and runs the ImageMagick configure per ABI with the NDK
# to generate the per-ABI config headers. Output lands in the git-ignored jniLibs/<abi> and
# cpp/imagemagick/{include,configs} that CMakeLists.txt reads.
#
# iOS: delegates to ios/build-imagemagick.sh (builds the static libraries from source into the
# git-ignored vendor/ tree).
#
# ffmpeg needs no fetch step: FFmpegKit is a Maven/SPM dependency the platform build resolves.
#
# Usage: scripts/fetch-mobile-media-tools.sh <android|ios|all>   (default: android)
set -euo pipefail

# The ImageMagick version. Must match the MolotovCherry release tag and the source tag so the
# generated headers agree with the prebuilt .so (quantum depth etc.).
IM_VERSION="7.1.2-26"

# The ABIs Android ships (release device + emulator/CI). The CMake config-overlay dir differs from
# the ABI name, so both are tracked here: "<abi>:<config-dir>:<ndk-triple>".
ANDROID_TARGETS=("arm64-v8a:arm64:aarch64-linux-android24" "x86_64:x86-64:x86_64-linux-android24")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_MAIN="$REPO_ROOT/apps/android-frontend/android/app/src/main"
JNILIBS_DIR="$ANDROID_MAIN/jniLibs"
IM_DIR="$ANDROID_MAIN/cpp/imagemagick"

# A git-ignored work area for downloads and the configure tree.
WORK_DIR="$REPO_ROOT/apps/android-frontend/android/.media-fetch"

log() {
    printf '[fetch-media] %s\n' "$1" >&2
}

# Resolves the Android NDK home from the environment or the SDK, failing loudly if absent.
resolve_ndk() {
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    for candidate in "${ANDROID_NDK_HOME:-}" "$sdk/ndk/25.1.8937393" "$sdk/ndk-bundle"; do
        if [ -n "$candidate" ] && [ -x "$candidate/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "ERROR: Android NDK 25.1.8937393 not found (set ANDROID_NDK_HOME or ANDROID_HOME)." >&2
    return 1
}

# True when the Android media artifacts are already in place, so the fetch is skipped on reruns.
android_already_fetched() {
    for target in "${ANDROID_TARGETS[@]}"; do
        local abi="${target%%:*}"
        local configDir; configDir="$(echo "$target" | cut -d: -f2)"
        [ -f "$JNILIBS_DIR/$abi/libmagickcore-7.so" ] || return 1
        [ -f "$JNILIBS_DIR/$abi/libmagickwand-7.so" ] || return 1
        [ -f "$IM_DIR/configs/$configDir/MagickCore/magick-baseconfig.h" ] || return 1
    done
    [ -f "$IM_DIR/include/MagickWand/MagickWand.h" ] || return 1
    return 0
}

# Downloads and extracts the ImageMagick source once into the work area, returning its path.
fetch_im_source() {
    local srcTar="$WORK_DIR/imagemagick-$IM_VERSION.tar.gz"
    local srcDir="$WORK_DIR/ImageMagick-$IM_VERSION"
    if [ ! -d "$srcDir" ]; then
        mkdir -p "$WORK_DIR"
        log "Downloading ImageMagick $IM_VERSION source..."
        curl -sL --fail -o "$srcTar" "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IM_VERSION.tar.gz"
        tar xzf "$srcTar" -C "$WORK_DIR"
    fi
    echo "$srcDir"
}

# Copies the ImageMagick API headers (the checked-in MagickCore/MagickWand headers) into the
# git-ignored include tree. The per-ABI generated magick-baseconfig.h / version.h are placed
# separately by android_configure_headers and take include precedence via CMakeLists.
install_api_headers() {
    local srcDir="$1"
    log "Installing ImageMagick API headers..."
    rm -rf "$IM_DIR/include"
    mkdir -p "$IM_DIR/include/MagickCore" "$IM_DIR/include/MagickWand"
    cp "$srcDir"/MagickCore/*.h "$IM_DIR/include/MagickCore/"
    cp "$srcDir"/MagickWand/*.h "$IM_DIR/include/MagickWand/"
}

# Runs ImageMagick configure for one ABI with the NDK toolchain and copies the two generated config
# headers into the git-ignored per-ABI config overlay. Quantum depth 16 + HDRI match the prebuilt .so.
android_configure_headers() {
    local ndk="$1" abi="$2" configDir="$3" triple="$4" srcDir="$5"
    local tc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local buildDir="$WORK_DIR/build-$abi"

    log "Configuring ImageMagick for $abi (generates per-ABI config headers)..."
    rm -rf "$buildDir"
    cp -r "$srcDir" "$buildDir"
    (
        cd "$buildDir"
        CC="$tc/${triple}-clang" AR="$tc/llvm-ar" RANLIB="$tc/llvm-ranlib" STRIP="$tc/llvm-strip" \
            ./configure --host="${triple%??}" --build=x86_64-pc-linux-gnu \
            --with-quantum-depth=16 --enable-hdri --disable-openmp --without-x \
            --disable-docs --without-magick-plus-plus --without-utilities --without-perl >/dev/null 2>&1
    )
    mkdir -p "$IM_DIR/configs/$configDir/MagickCore"
    cp "$buildDir/MagickCore/magick-baseconfig.h" "$IM_DIR/configs/$configDir/MagickCore/"
    cp "$buildDir/MagickCore/version.h" "$IM_DIR/configs/$configDir/MagickCore/"
}

# Downloads the prebuilt .so for one ABI from the MolotovCherry release into jniLibs/<abi>.
android_fetch_libs() {
    local abi="$1"
    local zip="$WORK_DIR/imagemagick-7-android-$abi.zip"
    local unpack="$WORK_DIR/lib-$abi"
    log "Downloading prebuilt ImageMagick .so for $abi..."
    curl -sL --fail -o "$zip" \
        "https://github.com/MolotovCherry/Android-ImageMagick7/releases/download/$IM_VERSION/imagemagick-7-android-$abi.zip"
    rm -rf "$unpack"; mkdir -p "$unpack"
    unzip -q -o "$zip" -d "$unpack"
    mkdir -p "$JNILIBS_DIR/$abi"
    cp "$unpack"/shared/libmagickcore-7.so "$JNILIBS_DIR/$abi/"
    cp "$unpack"/shared/libmagickwand-7.so "$JNILIBS_DIR/$abi/"
    cp "$unpack"/shared/libc++_shared.so "$JNILIBS_DIR/$abi/"
    cp "$unpack"/shared/libomp.so "$JNILIBS_DIR/$abi/"
}

# Fetches + builds all Android ImageMagick artifacts, unless already present.
fetch_android() {
    if android_already_fetched; then
        log "Android ImageMagick already present; skipping (delete $JNILIBS_DIR and $IM_DIR to refetch)."
        return 0
    fi

    local ndk; ndk="$(resolve_ndk)"
    local srcDir; srcDir="$(fetch_im_source)"
    install_api_headers "$srcDir"

    for target in "${ANDROID_TARGETS[@]}"; do
        local abi configDir triple
        abi="${target%%:*}"
        configDir="$(echo "$target" | cut -d: -f2)"
        triple="$(echo "$target" | cut -d: -f3)"
        android_fetch_libs "$abi"
        android_configure_headers "$ndk" "$abi" "$configDir" "$triple" "$srcDir"
    done

    log "Android ImageMagick ready (jniLibs + headers populated, all git-ignored)."
}

# True when the iOS ImageMagick static libraries are already built for both slices, so the (slow,
# from-source) build is skipped on reruns. Mirrors android_already_fetched.
ios_already_fetched() {
    local vendor="$REPO_ROOT/apps/ios-frontend/ios/App/vendor/im"
    [ -f "$vendor/device/lib/libMagickWand-7.Q8HDRI.a" ] || return 1
    [ -f "$vendor/sim/lib/libMagickWand-7.Q8HDRI.a" ] || return 1
    return 0
}

# Builds the iOS ImageMagick static libraries from source into the git-ignored vendor tree. Idempotent:
# skips the (slow) build when both slices are already present.
fetch_ios() {
    local script="$REPO_ROOT/apps/ios-frontend/ios/build-imagemagick.sh"
    if [ ! -f "$script" ]; then
        echo "ERROR: $script not found." >&2
        return 1
    fi
    if ios_already_fetched; then
        log "iOS ImageMagick already built (vendor/im present); skipping."
        return 0
    fi
    log "Building iOS ImageMagick from source (macOS/Xcode required)..."
    bash "$script"
}

main() {
    local platform="${1:-android}"
    case "$platform" in
        android) fetch_android ;;
        ios) fetch_ios ;;
        all) fetch_android; fetch_ios ;;
        *) echo "Usage: $0 <android|ios|all>" >&2; exit 1 ;;
    esac
}

main "$@"
