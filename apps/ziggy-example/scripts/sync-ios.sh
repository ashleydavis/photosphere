#!/usr/bin/env bash

# Puts what the iOS Xcode project needs into its native directory: the bundled page and the Zig static library for the SDK. See sync-ios.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
SDK="simulator"
ARCH="$(apple_host_arch)"
NATIVE_DIR="$APPLE_EXAMPLE_DIR/shells/ios/zig-out"
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
        --test-hooks)
            TEST_HOOKS="yes"
            shift
            ;;
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        *)
            apple_fail "unknown argument '$1'. Options: --sdk, --arch, --native-dir, --test-hooks, --optimize."
            ;;
    esac
done

case "$SDK" in
    simulator)
        ZIG_TARGET="$(apple_zig_arch "$ARCH")-ios.14.0-simulator"
        ;;
    device)
        if [ "$ARCH" != "arm64" ]; then
            apple_fail "an iOS device is arm64 only. Pass --arch arm64."
        fi
        ZIG_TARGET="aarch64-ios.14.0"
        ;;
    *)
        apple_fail "unknown --sdk '$SDK'. Use simulator or device."
        ;;
esac

apple_sync_native "$ZIG_TARGET" "$NATIVE_DIR" "$TEST_HOOKS" "$OPTIMIZE"
echo "Synced the iOS native files ($SDK, $ARCH) into $NATIVE_DIR"
