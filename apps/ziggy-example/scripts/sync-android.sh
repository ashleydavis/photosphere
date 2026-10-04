#!/usr/bin/env bash

# Builds what the Android app packages and puts it where Gradle expects it. See sync-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

arch_list="x86_64 arm64"
optimize="ReleaseSmall"
test_hooks="false"
skip_ui="false"
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
        --test-hooks)
            test_hooks="true"
            shift
            ;;
        --skip-ui)
            skip_ui="true"
            shift
            ;;
        *)
            echo "Usage: sync-android.sh [--arch \"x86_64 arm64\"] [--optimize Debug|ReleaseSafe|ReleaseFast|ReleaseSmall] [--test-hooks] [--skip-ui]" >&2
            exit 2
            ;;
    esac
done
if [ "$arch_list" = "all" ]; then
    arch_list="x86_64 arm64"
fi

ziggy_android_require_commands zig bun

generated_dir="$ZIGGY_ANDROID_PROJECT_DIR/app/build/ziggy"
core_dir="$ZIGGY_REPO_ROOT/packages-zig/ziggy-example-core"
ndk_version="$(ziggy_android_ndk_version)"
min_sdk="$(ziggy_android_min_sdk)"
sysroot="$ANDROID_HOME/ndk/$ndk_version/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [ "$(uname -s)" = "Darwin" ]; then
    sysroot="$ANDROID_HOME/ndk/$ndk_version/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
fi
if [ ! -d "$sysroot" ]; then
    echo "ERROR: the NDK sysroot is not at $sysroot. Run setup-android.sh." >&2
    exit 1
fi

mkdir -p "$generated_dir/zig-libc" "$generated_dir/assets/ui" "$generated_dir/jniLibs"

# Zig has no C library for Android, so it is given the NDK's as a libc file, one per ABI because the headers and the
# libraries differ. The libraries are the ones for the app's minimum SDK level, so the library links only against what that
# level has.
for arch in x86_64 arm64; do
    abi="$(ziggy_android_abi "$arch")"
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

test_hooks_argument="-Dtest-hooks=false"
if [ "$test_hooks" = "true" ]; then
    test_hooks_argument="-Dtest-hooks=true"
fi

# A library of another ABI left by an earlier sync is removed by name, so the APK holds only what was asked for.
for arch in x86_64 arm64; do
    rm -f "$generated_dir/jniLibs/$(ziggy_android_abi "$arch")/libziggy_example.so"
done

for arch in $arch_list; do
    abi="$(ziggy_android_abi "$arch")"
    case "$arch" in
        x86_64)
            triple="x86_64-linux-android"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
    esac
    echo "Building the Zig library for $abi ($optimize, $test_hooks_argument)..."
    (cd "$core_dir" && zig build \
        "-Dtarget=$triple" \
        "-Doptimize=$optimize" \
        "$test_hooks_argument" \
        --libc "$generated_dir/zig-libc/$arch.txt" \
        -p "$generated_dir/zig-out/$abi")
    mkdir -p "$generated_dir/jniLibs/$abi"
    cp "$generated_dir/zig-out/$abi/lib/libziggy_example.so" "$generated_dir/jniLibs/$abi/libziggy_example.so"
done

if [ "$skip_ui" = "false" ]; then
    echo "Building the page..."
    (cd "$ZIGGY_EXAMPLE_DIR" && bun run bundle:ui)
fi
if [ ! -f "$ZIGGY_EXAMPLE_DIR/dist/index.html" ]; then
    echo "ERROR: $ZIGGY_EXAMPLE_DIR/dist/index.html does not exist. Run without --skip-ui." >&2
    exit 1
fi

# The page is copied over the previous one, and files of an earlier build that this one no longer has are deleted, one
# file at a time, so a renamed script never lingers in the APK.
find "$generated_dir/assets/ui" -type f -delete
cp -R "$ZIGGY_EXAMPLE_DIR/dist/." "$generated_dir/assets/ui/"
cp "$ZIGGY_REPO_ROOT/packages/ziggy-bridge/inject/ziggy-inject.js" "$generated_dir/assets/ziggy-inject.js"
echo "Synced into $generated_dir"
