#!/usr/bin/env bash
# Takes a given upstream ImageMagick version's source into vendor/imagemagick. See update-imagemagick.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: scripts/update-imagemagick.sh <version>   (for example 7.1.2-33)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/vendor-library.sh"

# Left out: what is not the library or the program that runs it (other language bindings, the web site, tests, fuzzing,
# packaging, examples, the logos, the autoconf macros and the repository's own metadata).
vendor_library "$REPO_ROOT" imagemagick \
    "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$1.tar.gz" "$1" \
    PerlMagick www Magick++ tests oss-fuzz app-image api_examples logo scripts m4 index.html \
    .github .devcontainer .gitignore .gitattributes .editorconfig .auto-changelog
