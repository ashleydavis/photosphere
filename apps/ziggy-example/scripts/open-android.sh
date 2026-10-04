#!/usr/bin/env bash

# Opens the Android project in Android Studio. See open-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

bash "$ZIGGY_ANDROID_SCRIPTS_DIR/sync-android.sh"
studio_command="${ZIGGY_ANDROID_STUDIO:-}"
if [ -z "$studio_command" ]; then
    for candidate in android-studio studio studio.sh; do
        if command -v "$candidate" >/dev/null 2>&1; then
            studio_command="$candidate"
            break
        fi
    done
fi
if [ -z "$studio_command" ]; then
    echo "ERROR: Android Studio was not found on the PATH (tried android-studio, studio, studio.sh). Set ZIGGY_ANDROID_STUDIO to its launcher." >&2
    exit 1
fi
"$studio_command" "$ZIGGY_ANDROID_PROJECT_DIR" > /dev/null 2>&1 &
echo "Opening $ZIGGY_ANDROID_PROJECT_DIR in Android Studio."
