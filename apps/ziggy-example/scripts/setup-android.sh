#!/usr/bin/env bash

# One-time setup for building the example for Android. See setup-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

ziggy_android_require_commands zig bun jq unzip

bash "$ZIGGY_CAPACITOR_ANDROID_DIR/scripts/install-android-sdk.sh" --install

ndk_dir="$ANDROID_HOME/ndk/$(ziggy_android_ndk_version)"
if [ ! -d "$ndk_dir" ]; then
    echo "ERROR: the NDK is not at $ndk_dir after the install." >&2
    exit 1
fi
echo "Ready: JDK at $JAVA_HOME, SDK at $ANDROID_HOME, NDK at $ndk_dir."
