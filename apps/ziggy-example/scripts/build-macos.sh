#!/usr/bin/env bash

# Builds the MacOS app with xcodebuild, after syncing its page and Zig library. See build-macos.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
ARCH="$(apple_host_arch)"
NATIVE_DIR="$APPLE_EXAMPLE_DIR/shells/macos/zig-out"
BUILD_DIR="$APPLE_EXAMPLE_DIR/shells/macos/zig-out/xcode"
CONFIGURATION="Debug"
TEST_HOOKS="no"
OPTIMIZE="ReleaseSafe"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --native-dir)
            NATIVE_DIR="$2"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="$2"
            shift 2
            ;;
        --test-hooks)
            TEST_HOOKS="yes"
            shift
            ;;
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        *)
            apple_fail "unknown argument '$1'. Options: --arch, --native-dir, --build-dir, --configuration, --test-hooks, --optimize."
            ;;
    esac
done

if [ "$TEST_HOOKS" = "yes" ]; then
    bash "$SCRIPT_DIR/sync-macos.sh" --arch "$ARCH" --native-dir "$NATIVE_DIR" --optimize "$OPTIMIZE" --test-hooks
else
    bash "$SCRIPT_DIR/sync-macos.sh" --arch "$ARCH" --native-dir "$NATIVE_DIR" --optimize "$OPTIMIZE"
fi

xcodebuild \
    -project "$APPLE_EXAMPLE_DIR/shells/macos/ZiggyExample.xcodeproj" \
    -scheme ZiggyExample \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    -destination "generic/platform=macOS" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=NO \
    ZIGGY_NATIVE_DIR="$NATIVE_DIR" \
    MARKETING_VERSION="$(apple_package_version)" \
    build

echo "Built $BUILD_DIR/Build/Products/$CONFIGURATION/ZiggyExample.app"
