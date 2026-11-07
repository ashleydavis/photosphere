#!/usr/bin/env bash

# Checks that the tools the iOS build needs exist: Xcode 14.2 or newer and simctl. It installs nothing. See setup-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
apple_require_xcode
apple_require_tool jq rsync
if ! xcrun simctl help > /dev/null 2>&1; then
    apple_fail "xcrun simctl does not work. Install Xcode's iOS simulator support."
fi

# The first line of the output, taken in the shell: piping into head would end xcodebuild with a broken pipe once head had its line,
# which pipefail makes the script's failure (exit 141).
XCODE_VERSION="$(xcodebuild -version)"
XCODE_VERSION="${XCODE_VERSION%%$'\n'*}"
XCODE_VERSION="${XCODE_VERSION#Xcode }"
MAJOR="${XCODE_VERSION%%.*}"
REST="${XCODE_VERSION#*.}"
MINOR="${REST%%.*}"
if [ "$XCODE_VERSION" = "$REST" ]; then
    MINOR=0
fi
if [ "$MAJOR" -lt 14 ] || { [ "$MAJOR" -eq 14 ] && [ "$MINOR" -lt 2 ]; }; then
    apple_fail "Xcode $XCODE_VERSION is older than 14.2."
fi
echo "Xcode $XCODE_VERSION and simctl are present."
