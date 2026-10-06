#!/usr/bin/env bash

# Shared by the *-android.sh scripts. Source it, do not run it. See android-common.md.

ZIGGY_ANDROID_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIGGY_EXAMPLE_DIR="$(cd "$ZIGGY_ANDROID_SCRIPTS_DIR/.." && pwd)"
ZIGGY_REPO_ROOT="$(cd "$ZIGGY_EXAMPLE_DIR/../.." && pwd)"
ZIGGY_ANDROID_PROJECT_DIR="$ZIGGY_EXAMPLE_DIR/shells/android"
ZIGGY_ANDROID_APP_ID="dev.ziggy.example"
ZIGGY_CAPACITOR_ANDROID_DIR="$ZIGGY_REPO_ROOT/apps/android-frontend"

# Resolves JAVA_HOME (a JDK 17) and ANDROID_HOME, the same way the Photosphere Android app does. It exits with a message
# when either is missing.
source "$ZIGGY_CAPACITOR_ANDROID_DIR/scripts/android-env.sh"

#
# Fails with a message unless every named command is on the PATH. Usage: ziggy_android_require_commands <command...>
#
ziggy_android_require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: $command_name is not on the PATH. Run this through mise (for example: mise exec -- bun run <script>) so the pinned tools are used." >&2
            return 1
        fi
    done
}

#
# Prints the NDK version the Photosphere Android app pins, which this project uses too.
#
ziggy_android_ndk_version() {
    local version
    version="$(sed -n 's/^ *ndkVersion "\(.*\)".*$/\1/p' "$ZIGGY_CAPACITOR_ANDROID_DIR/android/app/build.gradle")"
    if [ -z "$version" ]; then
        echo "ERROR: no ndkVersion found in $ZIGGY_CAPACITOR_ANDROID_DIR/android/app/build.gradle" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

#
# Prints the minimum SDK level, from the variables the Photosphere Android app and this project share.
#
ziggy_android_min_sdk() {
    sed -n 's/^ *minSdkVersion = \([0-9]*\).*$/\1/p' "$ZIGGY_CAPACITOR_ANDROID_DIR/android/variables.gradle"
}

#
# Runs Gradle in the example's Android project. Usage: ziggy_android_gradle <gradle arguments...>
#
ziggy_android_gradle() {
    (cd "$ZIGGY_ANDROID_PROJECT_DIR" && ./gradlew "$@")
}

#
# Prints the example's version, from its package.json.
#
ziggy_android_version() {
    jq -r '.version' "$ZIGGY_EXAMPLE_DIR/package.json"
}

#
# Prints the Android ABI directory name for an architecture name: x86_64 or arm64. Usage: ziggy_android_abi <arch>
#
ziggy_android_abi() {
    case "$1" in
        x86_64)
            echo "x86_64"
            ;;
        arm64)
            echo "arm64-v8a"
            ;;
        *)
            echo "ERROR: unknown architecture '$1' (expected x86_64 or arm64)" >&2
            return 1
            ;;
    esac
}

#
# Writes the libc file Zig is given for an Android target, because Zig has no C library for Android and uses the NDK's. One file
# per architecture, because the headers and the libraries differ. The libraries are the ones for the given SDK level, so
# the program links only against what that level has. Usage: ziggy_android_write_libc_file <x86_64|arm64> <file> <sdk level>
#
ziggy_android_write_libc_file() {
    local arch="$1"
    local file="$2"
    local sdk_level="$3"
    local sysroot triple
    sysroot="$ANDROID_HOME/ndk/$(ziggy_android_ndk_version)/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    if [ "$(uname -s)" = "Darwin" ]; then
        sysroot="$ANDROID_HOME/ndk/$(ziggy_android_ndk_version)/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
    fi
    if [ ! -d "$sysroot" ]; then
        echo "ERROR: the NDK sysroot is not at $sysroot. Run setup-android.sh." >&2
        return 1
    fi
    case "$arch" in
        x86_64)
            triple="x86_64-linux-android"
            ;;
        arm64)
            triple="aarch64-linux-android"
            ;;
        *)
            echo "ERROR: unknown architecture '$arch' (expected x86_64 or arm64)" >&2
            return 1
            ;;
    esac
    {
        echo "include_dir=$sysroot/usr/include"
        echo "sys_include_dir=$sysroot/usr/include/$triple"
        echo "crt_dir=$sysroot/usr/lib/$triple/$sdk_level"
        echo "msvc_lib_dir="
        echo "kernel32_lib_dir="
        echo "gcc_dir="
    } > "$file"
}
