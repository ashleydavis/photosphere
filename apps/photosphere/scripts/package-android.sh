#!/usr/bin/env bash

# Builds the release APK for each architecture. See package-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

arch_list="x86_64 arm64"
output_dir="$PHOTOSPHERE_APP_DIR/out/android"
version="$(photosphere_android_version)"
version_code="1"
binary_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            arch_list="$2"
            shift 2
            ;;
        --binary)
            binary_dir="$2"
            shift 2
            ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --version-name)
            version="$2"
            shift 2
            ;;
        --version-code)
            version_code="$2"
            shift 2
            ;;
        *)
            echo "Usage: package-android.sh [--arch \"x86_64 arm64\"] [--binary <dir>] [--output-dir <dir>] [--version-name <name>] [--version-code <number>]" >&2
            exit 2
            ;;
    esac
done
if [ "$arch_list" = "all" ]; then
    arch_list="x86_64 arm64"
fi

mkdir -p "$output_dir"
for arch in $arch_list; do
    # The Zig library --binary names (build-android.sh --minify --output-dir <dir> keeps it in <dir>/jniLibs) goes into the APK as it
    # is, so the release workflow packages the library its app-build job made and smoke tested rather than compiling it a second
    # time. Without it the release library is built here. Either way the APK holds only this architecture's library.
    if [ -n "$binary_dir" ]; then
        abi="$(photosphere_android_abi "$arch")"
        library="$binary_dir/jniLibs/$abi/libphotosphere.so"
        if [ ! -f "$library" ]; then
            echo "$library does not exist." >&2
            exit 1
        fi
        for other in x86_64 arm64; do
            rm -f "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/ziggy/jniLibs/$(photosphere_android_abi "$other")/libphotosphere.so"
        done
        mkdir -p "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/ziggy/jniLibs/$abi"
        cp "$library" "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/ziggy/jniLibs/$abi/libphotosphere.so"
    else
        bash "$PHOTOSPHERE_ANDROID_SCRIPTS_DIR/sync-android.sh" --arch "$arch" --optimize ReleaseSafe --minify
    fi
    photosphere_android_gradle assembleRelease "-PziggyVersionName=$version" "-PziggyVersionCode=$version_code"
    artifact="$output_dir/photosphere-$version-android-$arch.apk"
    cp "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/outputs/apk/release/app-release.apk" "$artifact"
    echo "Packaged $artifact"
done
