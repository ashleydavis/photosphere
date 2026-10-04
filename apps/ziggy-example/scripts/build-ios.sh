#!/usr/bin/env bash

# Builds the iOS app with xcodebuild, after syncing its page and Zig library. See build-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
SDK="simulator"
ARCH="$(apple_host_arch)"
NATIVE_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out"
BUILD_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/xcode"
CONFIGURATION="Debug"
TEST_HOOKS="no"
OPTIMIZE="ReleaseSafe"

while [ $# -gt 0 ]; do
    case "$1" in
        --sdk)
            SDK="$2"
            shift 2
            ;;
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
            apple_fail "unknown argument '$1'. Options: --sdk, --arch, --native-dir, --build-dir, --configuration, --test-hooks, --optimize."
            ;;
    esac
done

case "$SDK" in
    simulator)
        XCODE_SDK="iphonesimulator"
        DESTINATION="generic/platform=iOS Simulator"
        PRODUCTS_NAME="$CONFIGURATION-iphonesimulator"
        ;;
    device)
        XCODE_SDK="iphoneos"
        DESTINATION="generic/platform=iOS"
        PRODUCTS_NAME="$CONFIGURATION-iphoneos"
        ;;
    *)
        apple_fail "unknown --sdk '$SDK'. Use simulator or device."
        ;;
esac

if [ "$TEST_HOOKS" = "yes" ]; then
    bash "$SCRIPT_DIR/sync-ios.sh" --sdk "$SDK" --arch "$ARCH" --native-dir "$NATIVE_DIR" --optimize "$OPTIMIZE" --test-hooks
else
    bash "$SCRIPT_DIR/sync-ios.sh" --sdk "$SDK" --arch "$ARCH" --native-dir "$NATIVE_DIR" --optimize "$OPTIMIZE"
fi

xcodebuild \
    -project "$APPLE_EXAMPLE_DIR/shells/ios/ZiggyExample.xcodeproj" \
    -scheme ZiggyExample \
    -configuration "$CONFIGURATION" \
    -sdk "$XCODE_SDK" \
    -derivedDataPath "$BUILD_DIR" \
    -destination "$DESTINATION" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    ZIGGY_NATIVE_DIR="$NATIVE_DIR" \
    MARKETING_VERSION="$(apple_package_version)" \
    build

echo "Built $BUILD_DIR/Build/Products/$PRODUCTS_NAME/ZiggyExample.app"
