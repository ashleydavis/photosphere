#!/usr/bin/env bash

# Builds the MacOS app (Debug, for this Mac's architecture), then runs it. Every argument goes to the app. See run-macos.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
bash "$SCRIPT_DIR/build-macos.sh"
exec "$APPLE_EXAMPLE_DIR/shells/macos/zig-out/xcode/Build/Products/Debug/ZiggyExample.app/Contents/MacOS/ZiggyExample" "$@"
