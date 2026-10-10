#!/usr/bin/env bash

# Removes Photosphere's Linux build output, one file at a time. See clean-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for directory in "$APP_DIR/../photosphere-frontend/dist" "$APP_DIR/shells/linux/zig-out" "$APP_DIR/shells/linux/.zig-cache" "$APP_DIR/out/linux"; do
    if [ -d "$directory" ]; then
        find "$directory" -type f -delete
    fi
done
