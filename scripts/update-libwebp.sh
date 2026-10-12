#!/usr/bin/env bash
# Takes a given upstream libwebp version's source into vendor/libwebp. See update-libwebp.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: scripts/update-libwebp.sh <version>   (for example 1.6.0)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/vendor-library.sh"

# Left out: the example programs, the documentation and the test pictures.
vendor_library "$REPO_ROOT" libwebp "https://github.com/webmproject/libwebp/archive/refs/tags/v$1.tar.gz" "$1" \
    examples doc tests .github .gitignore .gitattributes
