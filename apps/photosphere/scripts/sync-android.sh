#!/usr/bin/env bash

# Builds what the Android app packages and puts it where Gradle expects it. See sync-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

arch_list="x86_64 arm64"
optimize="ReleaseSafe"
skip_ui="false"
bundle_arguments=()
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            arch_list="$2"
            shift 2
            ;;
        --optimize)
            optimize="$2"
            shift 2
            ;;
        --minify)
            bundle_arguments=(--minify)
            shift
            ;;
        --skip-ui)
            skip_ui="true"
            shift
            ;;
        *)
            echo "Usage: sync-android.sh [--arch \"x86_64 arm64\"] [--optimize Debug|ReleaseSafe|ReleaseFast|ReleaseSmall] [--minify] [--skip-ui]" >&2
            exit 2
            ;;
    esac
done
if [ "$arch_list" = "all" ]; then
    arch_list="x86_64 arm64"
fi

photosphere_android_require_commands zig bun

# ImageMagick runs inside the app (Android has no program to start), linked from libraries and headers fetched into git-ignored
# directories. The fetch skips what is already there.
bash "$PHOTOSPHERE_REPO_ROOT/scripts/fetch-mobile-media-tools.sh" android

generated_dir="$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/ziggy"
ndk_version="$(photosphere_android_ndk_version)"
min_sdk="$(photosphere_android_min_sdk)"
sysroot="$ANDROID_HOME/ndk/$ndk_version/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [ "$(uname -s)" = "Darwin" ]; then
    sysroot="$ANDROID_HOME/ndk/$ndk_version/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
fi
if [ ! -d "$sysroot" ]; then
    echo "ERROR: the NDK sysroot is not at $sysroot. Run setup-android.sh." >&2
    exit 1
fi

mkdir -p "$generated_dir/zig-libc" "$generated_dir/jniLibs"

# Zig has no C library for Android, so it is given the NDK's as a libc file, one per ABI because the headers and the
# libraries differ. The libraries are the ones for the app's minimum SDK level, so the library links only against what that
# level has.
for arch in x86_64 arm64; do
    abi="$(photosphere_android_abi "$arch")"
    case "$arch" in
        x86_64)
            triple="x86_64-linux-android"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
    esac
    {
        echo "include_dir=$sysroot/usr/include"
        echo "sys_include_dir=$sysroot/usr/include/$triple"
        echo "crt_dir=$sysroot/usr/lib/$triple/$min_sdk"
        echo "msvc_lib_dir="
        echo "kernel32_lib_dir="
        echo "gcc_dir="
    } > "$generated_dir/zig-libc/$arch.txt"
done

# The page is embedded in the library, so it is built first, into a directory of this build's own, so a build of another platform
# running at the same moment cannot replace it mid-build. Removed afterwards. --skip-ui embeds the page already in dist instead.
page_directory="apps/photosphere-frontend/dist"
if [ "$skip_ui" = "false" ]; then
    echo "Building the page..."
    frontend_dir="$(cd "$PHOTOSPHERE_APP_DIR/../photosphere-frontend" && pwd)"
    page_dir="$(mktemp -d "$frontend_dir/page.XXXXXX")"
    trap 'find "$page_dir" -type f -delete; find "$page_dir" -depth -type d -empty -delete' EXIT
    (cd "$PHOTOSPHERE_APP_DIR" && bun run bundle:ui --out-dir "$page_dir" "${bundle_arguments[@]+"${bundle_arguments[@]}"}")
    page_directory="apps/photosphere-frontend/$(basename "$page_dir")"
fi
if [ ! -f "$PHOTOSPHERE_REPO_ROOT/$page_directory/index.html" ]; then
    echo "ERROR: $PHOTOSPHERE_REPO_ROOT/$page_directory/index.html does not exist. Run without --skip-ui." >&2
    exit 1
fi

# A library of another ABI left by an earlier sync is removed by name, so the APK holds only what was asked for.
for arch in x86_64 arm64; do
    rm -f "$generated_dir/jniLibs/$(photosphere_android_abi "$arch")/libphotosphere.so"
done

for arch in $arch_list; do
    abi="$(photosphere_android_abi "$arch")"
    case "$arch" in
        x86_64)
            triple="x86_64-linux-android"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
    esac
    echo "Building the Zig library for $abi ($optimize)..."
    (cd "$PHOTOSPHERE_REPO_ROOT" && zig build photosphere-backend \
        "-Dtarget=$triple" \
        "-Doptimize=$optimize" \
        "-Dui-directory=$page_directory" \
        --libc "$generated_dir/zig-libc/$arch.txt" \
        -p "$generated_dir/zig-out/$abi")
    mkdir -p "$generated_dir/jniLibs/$abi"
    cp "$generated_dir/zig-out/$abi/lib/libphotosphere.so" "$generated_dir/jniLibs/$abi/libphotosphere.so"
done

# An earlier version of this script put the page and the inject script in the assets. Both are in the library now, so the old
# copies are deleted, one file at a time, rather than left to be packaged into the APK.
if [ -d "$generated_dir/assets" ]; then
    find "$generated_dir/assets" -type f -delete
fi
echo "Synced into $generated_dir"
