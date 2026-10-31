#!/usr/bin/env bash

# Shared by the *-android.sh scripts. Source it, do not run it. See android-common.md.

PHOTOSPHERE_ANDROID_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTOSPHERE_APP_DIR="$(cd "$PHOTOSPHERE_ANDROID_SCRIPTS_DIR/.." && pwd)"
PHOTOSPHERE_REPO_ROOT="$(cd "$PHOTOSPHERE_APP_DIR/../.." && pwd)"
PHOTOSPHERE_ANDROID_PROJECT_DIR="$PHOTOSPHERE_APP_DIR/native/android"
PHOTOSPHERE_ANDROID_APP_ID="au.com.codecapers.photosphere.ziggy"
PHOTOSPHERE_ANDROID_TOOLS_DIR="$PHOTOSPHERE_REPO_ROOT/scripts/android"

# Resolves JAVA_HOME (a JDK 17) and ANDROID_HOME, with the repository's Android tools (scripts/android). It exits with a message
# when either is missing.
source "$PHOTOSPHERE_ANDROID_TOOLS_DIR/android-env.sh"

#
# Fails with a message unless every named command is on the PATH. Usage: photosphere_android_require_commands <command...>
#
photosphere_android_require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: $command_name is not on the PATH. Run mise install from the repository root so the pinned tools are used." >&2
            return 1
        fi
    done
}

#
# Prints the NDK version this project pins, from its variables.gradle.
#
photosphere_android_ndk_version() {
    local version
    version="$(sed -n 's/^ *ndkVersion = "\(.*\)".*$/\1/p' "$PHOTOSPHERE_ANDROID_PROJECT_DIR/variables.gradle")"
    if [ -z "$version" ]; then
        echo "ERROR: no ndkVersion found in $PHOTOSPHERE_ANDROID_PROJECT_DIR/variables.gradle" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

#
# Prints the minimum SDK level, from this project's variables.gradle.
#
photosphere_android_min_sdk() {
    sed -n 's/^ *minSdkVersion = \([0-9]*\).*$/\1/p' "$PHOTOSPHERE_ANDROID_PROJECT_DIR/variables.gradle"
}

#
# Runs Gradle in Photosphere's Android project. Usage: photosphere_android_gradle <gradle arguments...>
#
photosphere_android_gradle() {
    (cd "$PHOTOSPHERE_ANDROID_PROJECT_DIR" && ./gradlew "$@")
}

#
# Prints Photosphere's version, from its package.json.
#
photosphere_android_version() {
    jq -r '.version' "$PHOTOSPHERE_APP_DIR/package.json"
}

#
# Prints the Android ABI directory name for an architecture name: x86_64 or arm64. Usage: photosphere_android_abi <arch>
#
photosphere_android_abi() {
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
# the program links only against what that level has. Usage: photosphere_android_write_libc_file <x86_64|arm64> <file> <sdk level>
#
photosphere_android_write_libc_file() {
    local arch="$1"
    local file="$2"
    local sdk_level="$3"
    local sysroot triple
    sysroot="$ANDROID_HOME/ndk/$(photosphere_android_ndk_version)/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    if [ "$(uname -s)" = "Darwin" ]; then
        sysroot="$ANDROID_HOME/ndk/$(photosphere_android_ndk_version)/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
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
