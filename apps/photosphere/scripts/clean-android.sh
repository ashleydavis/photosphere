#!/usr/bin/env bash

# Cleans the Android project with Gradle's own clean and removes the packages. See clean-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

photosphere_android_gradle clean
if [ -d "$PHOTOSPHERE_APP_DIR/out/android" ]; then
    find "$PHOTOSPHERE_APP_DIR/out/android" -type f -delete
fi
