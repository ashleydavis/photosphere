#!/usr/bin/env bash
# Moves the zlib-ng this build fetches to a given upstream version. See update-zlib-ng.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: third-party/zlib-ng/update-zlib-ng.sh <version>   (for example 2.3.3)" >&2
    exit 1
fi

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# zig fetch downloads the release, works out its hash and writes the url and the hash into build.zig.zon's zlib-ng entry.
cd "$PACKAGE_DIR"
zig fetch --save=zlib-ng "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$1.tar.gz"
