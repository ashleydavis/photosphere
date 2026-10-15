#!/usr/bin/env bash

# One-time setup for building Photosphere for Android. See setup-android.md.

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The install runs first, because android-common.sh stops when the JDK 17 or the Android SDK it installs is missing.
bash "$scripts_dir/../../android-frontend/scripts/install-android-sdk.sh" --install

source "$scripts_dir/android-common.sh"

photosphere_android_require_commands zig bun jq unzip

ndk_dir="$ANDROID_HOME/ndk/$(photosphere_android_ndk_version)"
if [ ! -d "$ndk_dir" ]; then
    echo "ERROR: the NDK is not at $ndk_dir after the install." >&2
    exit 1
fi
echo "Ready: JDK at $JAVA_HOME, SDK at $ANDROID_HOME, NDK at $ndk_dir."
