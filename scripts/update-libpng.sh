#!/usr/bin/env bash
# Takes a given upstream libpng version's source into vendor/libpng. See update-libpng.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: scripts/update-libpng.sh <version>   (for example 1.6.50)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/vendor-library.sh"

# Left out: the test pictures and the contributed programs and projects.
vendor_library "$REPO_ROOT" libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$1.tar.gz" "$1" \
    contrib .github projects tests .gitignore .gitattributes
