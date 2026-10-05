#!/usr/bin/env bash

# Archives the iOS app for a device with code signing off, and packs the unsigned app as an .ipa. See package-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
apple_require_tool ditto jq rsync
OUTPUT_DIR="$APPLE_EXAMPLE_DIR/out/ios"
BUILD_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out/package"

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            apple_fail "unknown argument '$1'. Options: --output-dir."
            ;;
    esac
done

VERSION="$(apple_package_version)"
BASE_NAME="ziggy-example-$VERSION-ios-arm64"
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

bash "$SCRIPT_DIR/sync-ios.sh" --sdk device --arch arm64 --native-dir "$BUILD_DIR/native"
xcodebuild archive \
    -project "$APPLE_EXAMPLE_DIR/shells/ios/ZiggyExample.xcodeproj" \
    -scheme ZiggyExample \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -archivePath "$OUTPUT_DIR/$BASE_NAME.xcarchive" \
    -derivedDataPath "$BUILD_DIR/xcode" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    ZIGGY_NATIVE_DIR="$BUILD_DIR/native" \
    MARKETING_VERSION="$VERSION"

# An .ipa is a zip with the app inside a Payload directory. The staging directory is reused between runs and brought into
# line with the new archive.
mkdir -p "$BUILD_DIR/ipa-staging/Payload/ZiggyExample.app"
rsync -a --delete "$OUTPUT_DIR/$BASE_NAME.xcarchive/Products/Applications/ZiggyExample.app/" "$BUILD_DIR/ipa-staging/Payload/ZiggyExample.app/"
(cd "$BUILD_DIR/ipa-staging" && ditto -c -k --sequesterRsrc --keepParent Payload "$OUTPUT_DIR/$BASE_NAME.ipa")

echo "Archived $OUTPUT_DIR/$BASE_NAME.xcarchive and packed the unsigned $OUTPUT_DIR/$BASE_NAME.ipa"
