#!/usr/bin/env bash

# Cleans the iOS build with xcodebuild's own clean and removes the synced Zig library and header and the packages. See clean-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_ios
apple_require_xcode
NATIVE_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out"
BUILD_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/xcode"

while [ $# -gt 0 ]; do
    case "$1" in
        --native-dir)
            NATIVE_DIR="$2"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        *)
            apple_fail "unknown argument '$1'. Options: --native-dir, --build-dir."
            ;;
    esac
done

for configuration in Debug Release; do
    xcodebuild \
        -project "$APPLE_EXAMPLE_DIR/shells/ios/ZiggyExample.xcodeproj" \
        -scheme ZiggyExample \
        -configuration "$configuration" \
        -sdk iphonesimulator \
        -derivedDataPath "$BUILD_DIR" \
        -destination "generic/platform=iOS Simulator" \
        ZIGGY_NATIVE_DIR="$NATIVE_DIR" \
        clean
done
rm -f "$NATIVE_DIR/lib/libziggy_example.a" "$NATIVE_DIR/include/ziggy.h"
if [ -d "$APPLE_EXAMPLE_DIR/out/ios" ]; then
    find "$APPLE_EXAMPLE_DIR/out/ios" -type f -delete
fi
echo "Cleaned the iOS build."
