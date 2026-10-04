#!/usr/bin/env bash

# Syncs the page and Zig library, then opens the iOS Xcode project. See open-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
bash "$SCRIPT_DIR/sync-ios.sh" "$@"
open "$APPLE_EXAMPLE_DIR/shells/ios/ZiggyExample.xcodeproj"
