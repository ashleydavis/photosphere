#!/usr/bin/env bash

# Syncs, then builds the debug APK with Gradle. See build-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

sync_arguments=()
while [ $# -gt 0 ]; do
    case "$1" in
        --arch|--optimize)
            sync_arguments+=("$1" "$2")
            shift 2
            ;;
        --test-hooks)
            sync_arguments+=("$1")
            shift
            ;;
        *)
            echo "Usage: build-android.sh [--arch \"x86_64 arm64\"] [--optimize <mode>] [--test-hooks]" >&2
            exit 2
            ;;
    esac
done

bash "$ZIGGY_ANDROID_SCRIPTS_DIR/sync-android.sh" "${sync_arguments[@]+"${sync_arguments[@]}"}"
ziggy_android_gradle assembleDebug "-PziggyVersionName=$(ziggy_android_version)"
echo "APK: $ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
