#!/usr/bin/env bash

# Syncs, then builds the debug APK with Gradle. See build-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

sync_arguments=()
output_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --arch|--optimize)
            sync_arguments+=("$1" "$2")
            shift 2
            ;;
        *)
            echo "Usage: build-android.sh [--arch \"x86_64 arm64\"] [--optimize <mode>] [--output-dir <dir>]" >&2
            exit 2
            ;;
    esac
done

bash "$PHOTOSPHERE_ANDROID_SCRIPTS_DIR/sync-android.sh" "${sync_arguments[@]+"${sync_arguments[@]}"}"
photosphere_android_gradle assembleDebug "-PziggyVersionName=$(photosphere_android_version)"
echo "APK: $PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [ -n "$output_dir" ]; then
    mkdir -p "$output_dir"
    cp "$PHOTOSPHERE_ANDROID_PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk" "$output_dir/photosphere.apk"
    echo "Copied the APK to $output_dir/photosphere.apk"
fi
