#!/usr/bin/env bash
# One-time setup for the iOS app: generate and sync the native iOS project and install its CocoaPods.
# iOS builds are macOS only (they need Xcode and CocoaPods), so on any other OS this skips cleanly and
# succeeds, which lets the repo-wide `bun run setup` run on a Linux or Windows dev box without failing.
set -euo pipefail

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo "ios-frontend setup: skipped (iOS builds require macOS; this is $OS)."
    exit 0
fi

# Xcode and CocoaPods are hard prerequisites on macOS; `cap sync ios` runs `pod install`, which needs
# both. Fail loudly with what to install rather than letting cap fail deeper with a murkier message.
if ! xcode-select -p > /dev/null 2>&1; then
    echo "ERROR: Xcode is required for iOS (14.1+). Install it from the App Store, then re-run." >&2
    exit 1
fi
if ! command -v pod > /dev/null 2>&1; then
    echo "ERROR: CocoaPods is required for iOS. Install it (e.g. 'brew install cocoapods'), then re-run." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# `sync` builds the web assets, fetches the native media tools, and runs `cap sync ios`, which installs
# the CocoaPods into the native project. This is the documented one-time iOS setup step.
echo "ios-frontend setup: syncing the native iOS project (runs pod install)..."
cd "$APP_DIR"
bun run sync
echo "ios-frontend setup: done."
