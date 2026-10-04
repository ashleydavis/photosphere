#!/usr/bin/env bash

# Puts what the MacOS Xcode project needs into its native directory: the bundled page and the Zig static library. See sync-macos.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/apple-common.sh"

apple_require_macos
ARCH="$(apple_host_arch)"
NATIVE_DIR="$APPLE_EXAMPLE_DIR/shells/macos/zig-out"
TEST_HOOKS="no"
OPTIMIZE="ReleaseSafe"

while [ $# -gt 0 ]; do
    case "$1" in
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
            apple_fail "unknown argument '$1'. Options: --arch, --native-dir, --test-hooks, --optimize."
            ;;
    esac
done

apple_sync_native "$(apple_zig_arch "$ARCH")-macos.11.0" "$NATIVE_DIR" "$TEST_HOOKS" "$OPTIMIZE"
echo "Synced the MacOS native files into $NATIVE_DIR"
