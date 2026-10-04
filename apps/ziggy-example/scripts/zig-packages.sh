#!/usr/bin/env bash

# Builds, cross-builds or tests the Zig packages the Ziggy example is made of. See zig-packages.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$SCRIPT_DIR/../../../packages-zig" && pwd)"

ACTION="${1:-}"
case "$ACTION" in
    build)
        (cd "$PACKAGES_DIR/ziggy-example-core" && zig build)
        ;;
    cross)
        # The example's core library for every platform that is not this one, with and without the test hooks. The
        # Apple targets carry the oldest OS version each is meant to run on.
        for target in aarch64-macos.11.0 x86_64-macos.11.0 aarch64-ios.14.0 aarch64-ios.14.0-simulator x86_64-ios.14.0-simulator x86_64-windows-gnu aarch64-windows-gnu x86_64-linux-gnu aarch64-linux-gnu; do
            for hooks in false true; do
                echo "Cross-building the example core for $target (test hooks: $hooks)"
                (cd "$PACKAGES_DIR/ziggy-example-core" && zig build -Dtarget="$target" -Dtest-hooks="$hooks" -p "zig-out/cross/$target-$hooks")
            done
        done
        # The Windows shell, which needs the WebView2 SDK, fetched once and then reused.
        bash "$SCRIPT_DIR/fetch-webview2.sh"
        for target in x86_64-windows-gnu aarch64-windows-gnu; do
            echo "Cross-building the Windows shell for $target"
            (cd "$EXAMPLE_DIR/shells/windows" && zig build -Dtarget="$target" -p "zig-out/cross/$target")
        done
        ;;
    test)
        (cd "$PACKAGES_DIR/ziggy-core" && zig build test --summary all --test-timeout 20m)
        (cd "$PACKAGES_DIR/ziggy-example-core" && zig build test --summary all --test-timeout 20m)
        (cd "$PACKAGES_DIR/ziggy-shell-windows" && zig build test --summary all --test-timeout 20m)
        (cd "$PACKAGES_DIR/ziggy-shell-linux" && zig build test --summary all --test-timeout 20m)
        ;;
    *)
        echo "Usage: zig-packages.sh <build|cross|test>" >&2
        exit 2
        ;;
esac
