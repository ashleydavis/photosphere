#!/usr/bin/env bash
# Builds ImageMagick (with its libjpeg, libpng and zlib) as a static library for one target, from the source in vendor/. See build-imagemagick.md.
set -euo pipefail

usage() {
    echo "Usage: scripts/build-imagemagick.sh [--target <zig-target>] [--libc-file <file>] [--output-dir <dir>]" >&2
    echo "  --target      the target to build for (default: this machine). One of x86_64-linux-gnu, aarch64-linux-gnu," >&2
    echo "                x86_64-linux-android, aarch64-linux-android, x86_64-windows-gnu, x86_64-macos, aarch64-macos," >&2
    echo "                aarch64-ios, aarch64-ios-simulator or x86_64-ios-simulator" >&2
    echo "  --libc-file   Zig's libc file for the NDK, required for the Android targets" >&2
    echo "  --output-dir  where the library is installed (default: zig-out/imagemagick/<target>)" >&2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=""
LIBC_FILE=""
OUTPUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --libc-file)
            LIBC_FILE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

ARGUMENTS=()
if [ -n "$TARGET" ]; then
    ARGUMENTS+=("-Dtarget=$TARGET")
fi
if [ -n "$LIBC_FILE" ]; then
    ARGUMENTS+=(--libc "$LIBC_FILE")
fi
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$REPO_ROOT/zig-out/imagemagick/${TARGET:-native}"
fi

cd "$REPO_ROOT"
zig build imagemagick ${ARGUMENTS[@]+"${ARGUMENTS[@]}"} -p "$OUTPUT_DIR"
echo "Built the library in $OUTPUT_DIR/lib"
