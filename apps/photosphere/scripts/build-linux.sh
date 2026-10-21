#!/usr/bin/env bash

# Builds Photosphere's Linux app. See build-linux.md.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/sync-linux.sh" "$@"
echo "Built $SCRIPT_DIR/../native/linux/zig-out/bin/photosphere"
