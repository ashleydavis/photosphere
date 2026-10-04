#!/usr/bin/env bash

# Removes the example's Linux build output, one file at a time. See clean-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for directory in "$EXAMPLE_DIR/dist" "$EXAMPLE_DIR/shells/linux/zig-out" "$EXAMPLE_DIR/shells/linux/.zig-cache" "$EXAMPLE_DIR/out/linux"; do
    if [ -d "$directory" ]; then
        find "$directory" -type f -delete
    fi
done
