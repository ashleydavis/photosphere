#!/usr/bin/env bash

# Builds the MacOS app in Release and packs it as a .dmg and a .zip. See package-macos.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
apple_require_tool hdiutil ditto jq
ARCH="$(apple_host_arch)"
OUTPUT_DIR="$APPLE_EXAMPLE_DIR/out/macos"
BUILD_DIR="$APPLE_EXAMPLE_DIR/shells/macos/zig-out/package"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            apple_fail "unknown argument '$1'. Options: --arch, --output-dir."
            ;;
    esac
done

VERSION="$(apple_package_version)"
BASE_NAME="ziggy-example-$VERSION-macos-$ARCH"
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

bash "$SCRIPT_DIR/build-macos.sh" --arch "$ARCH" --configuration Release --native-dir "$BUILD_DIR/native" --build-dir "$BUILD_DIR/xcode"
APP="$BUILD_DIR/xcode/Build/Products/Release/ZiggyExample.app"

# The disk image holds the app and a link to /Applications. The staging directory is reused between runs and brought into
# line with the new build.
mkdir -p "$BUILD_DIR/dmg-staging/ZiggyExample.app"
rsync -a --delete "$APP/" "$BUILD_DIR/dmg-staging/ZiggyExample.app/"
ln -sfn /Applications "$BUILD_DIR/dmg-staging/Applications"
hdiutil create -volname "Ziggy example" -srcfolder "$BUILD_DIR/dmg-staging" -ov -format UDZO "$OUTPUT_DIR/$BASE_NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/$BASE_NAME.zip"

echo "Packed $OUTPUT_DIR/$BASE_NAME.dmg and $OUTPUT_DIR/$BASE_NAME.zip"
