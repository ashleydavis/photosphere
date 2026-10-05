#!/usr/bin/env bash

# Builds the page and the Windows shell and installs everything the app needs into one directory. See sync-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

arch="x64"
prefix="$WINDOWS_SHELL_DIR/zig-out"
optimize="Debug"
test_hooks="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)
            arch="$2"
            shift 2
            ;;
        --prefix)
            prefix="$2"
            shift 2
            ;;
        --optimize)
            optimize="$2"
            shift 2
            ;;
        --test-hooks)
            test_hooks="true"
            shift
            ;;
        *)
            echo "Unknown argument $1. See sync-windows.md." >&2
            exit 2
            ;;
    esac
done

zig_target="$(windows_zig_target "$arch")"

windows_require_commands bun zig

if [ ! -f "$WINDOWS_SDK_DIR/include/WebView2.h" ]; then
    echo "The WebView2 SDK is not fetched. Run \"bun run --filter=ziggy-example setup\" from the repository root first." >&2
    exit 1
fi

(cd "$WINDOWS_EXAMPLE_DIR" && bun run bundle:ui)
(cd "$WINDOWS_SHELL_DIR" && zig build "-Dtarget=$zig_target" "-Doptimize=$optimize" "-Dtest-hooks=$test_hooks" -p "$prefix")
echo "Built into $prefix/$WINDOWS_APP_DIR_NAME"
