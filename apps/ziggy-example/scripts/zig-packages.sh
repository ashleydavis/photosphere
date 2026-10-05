#!/usr/bin/env bash

# Builds, cross-builds or tests the Zig packages the Ziggy example is made of. See zig-packages.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIGGY_DIR="$(cd "$SCRIPT_DIR/../../../packages/ziggy" && pwd)"

# The example's core embeds the built page, so the page is built before anything here.
(cd "$EXAMPLE_DIR" && bun run bundle:ui)

ACTION="${1:-}"
case "$ACTION" in
    build)
        (cd "$EXAMPLE_DIR/core" && zig build)
        ;;
    cross)
        # The example's core library for every platform that is not this one, with and without the test hooks. The
        # Apple targets carry the oldest OS version each is meant to run on.
        for target in aarch64-macos.11.0 x86_64-macos.11.0 aarch64-ios.14.0 aarch64-ios.14.0-simulator x86_64-ios.14.0-simulator x86_64-windows-gnu aarch64-windows-gnu x86_64-linux-gnu aarch64-linux-gnu; do
            for hooks in false true; do
                echo "Cross-building the example core for $target (test hooks: $hooks)"
                (cd "$EXAMPLE_DIR/core" && zig build -Dtarget="$target" -Dtest-hooks="$hooks" -p "zig-out/cross/$target-$hooks")
            done
        done
        # The Windows shell, which needs the WebView2 SDK, fetched once and then reused. It is only compiled here, not linked: the
        # link needs Microsoft's toolchain, which is on a Windows machine, and Zig has no Windows headers for that toolchain, so
        # the check uses the MinGW target, which has them.
        bash "$SCRIPT_DIR/fetch-webview2.sh"
        for target in x86_64-windows-gnu aarch64-windows-gnu; do
            echo "Checking the Windows shell for $target"
            (cd "$EXAMPLE_DIR/shells/windows" && zig build check -Dtarget="$target" -Dcompile-only=true)
        done
        ;;
    test)
        (cd "$ZIGGY_DIR/core" && zig build test --summary all --test-timeout 20m)
        (cd "$EXAMPLE_DIR/core" && zig build test --summary all --test-timeout 20m)
        (cd "$ZIGGY_DIR/native/windows" && zig build test --summary all --test-timeout 20m)
        (cd "$ZIGGY_DIR/native/linux" && zig build test --summary all --test-timeout 20m)
        ;;
    *)
        echo "Usage: zig-packages.sh <build|cross|test>" >&2
        exit 2
        ;;
esac
