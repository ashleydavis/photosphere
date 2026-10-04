#!/usr/bin/env bash

# Cleans the Android project with Gradle's own clean. See clean-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

ziggy_android_gradle clean
