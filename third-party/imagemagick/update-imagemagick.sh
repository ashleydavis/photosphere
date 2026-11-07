#!/usr/bin/env bash
# Takes a given upstream ImageMagick version's source into vendor/imagemagick. See update-imagemagick.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: third-party/imagemagick/update-imagemagick.sh <version>   (for example 7.1.2-33)" >&2
    exit 1
fi

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGE_DIR/vendor-library.sh"

# Left out: what is not the library or the program that runs it (other language bindings, the web site, tests, fuzzing,
# packaging, examples, the logos, the autoconf macros and the repository's own metadata).
vendor_library "$PACKAGE_DIR" imagemagick \
    "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$1.tar.gz" "$1" \
    PerlMagick www Magick++ tests oss-fuzz app-image api_examples logo scripts m4 index.html \
    .github .devcontainer .gitignore .gitattributes .editorconfig .auto-changelog

# MagickCore/threshold-map.h, which MagickCore/threshold.c includes, made from config/thresholds.xml with the command
# MagickCore/Makefile.am makes it with.
mkdir -p "$PACKAGE_DIR/config/common/MagickCore"
{
    printf '%s\n  %s=\n' 'static const char *const' BuiltinMap
    sed -e 's/"/\\"/g; s/^.*$/    "&\\n"/; $s/$/;/' "$PACKAGE_DIR/vendor/imagemagick/config/thresholds.xml"
} > "$PACKAGE_DIR/config/common/MagickCore/threshold-map.h"
