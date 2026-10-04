#!/usr/bin/env bash

# Builds the release APK for each architecture. See package-android.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/android-common.sh"

arch_list="x86_64 arm64"
output_dir="$ZIGGY_EXAMPLE_DIR/release"
version="$(ziggy_android_version)"
version_code="1"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            arch_list="$2"
            shift 2
            ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --version-name)
            version="$2"
            shift 2
            ;;
        --version-code)
            version_code="$2"
            shift 2
            ;;
        *)
            echo "Usage: package-android.sh [--arch \"x86_64 arm64\"] [--output-dir <dir>] [--version-name <name>] [--version-code <number>]" >&2
            exit 2
            ;;
    esac
done
if [ "$arch_list" = "all" ]; then
    arch_list="x86_64 arm64"
fi

mkdir -p "$output_dir"
for arch in $arch_list; do
    bash "$ZIGGY_ANDROID_SCRIPTS_DIR/sync-android.sh" --arch "$arch" --optimize ReleaseSmall
    ziggy_android_gradle assembleRelease "-PziggyVersionName=$version" "-PziggyVersionCode=$version_code"
    artifact="$output_dir/ziggy-example-$version-android-$arch.apk"
    cp "$ZIGGY_ANDROID_PROJECT_DIR/app/build/outputs/apk/release/app-release.apk" "$artifact"
    echo "Packaged $artifact"
done
