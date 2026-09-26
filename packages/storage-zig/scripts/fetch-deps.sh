#!/bin/bash
#
# Fetches every dependency in build.zig.zon into Zig's global package cache, one `zig fetch` at a
# time, so a later `zig build` finds them all by hash and downloads nothing.
#
# `zig build` downloads missing dependencies concurrently over pooled connections, and in CI that
# fails with "invalid HTTP response: HttpConnectionClosing" when it reuses a connection GitHub has
# already closed. Each `zig fetch` here is its own process with its own connections, so none is
# ever reused.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

grep -oE '\.url = "[^"]+"' "$SCRIPT_DIR/../build.zig.zon" | sed -E 's/\.url = "([^"]+)"/\1/' | while read -r dependency_url; do
    echo "Fetching $dependency_url"
    zig fetch "$dependency_url"
done
