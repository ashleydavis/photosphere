#!/usr/bin/env bash

# Syncs the page and Zig library, then opens the MacOS Xcode project. See open-macos.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
bash "$SCRIPT_DIR/sync-macos.sh" "$@"
open "$APPLE_EXAMPLE_DIR/shells/macos/ZiggyExample.xcodeproj"
