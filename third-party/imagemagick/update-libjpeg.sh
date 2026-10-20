#!/usr/bin/env bash
# Takes a given upstream Independent JPEG Group libjpeg release into vendor/libjpeg. See update-libjpeg.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: third-party/imagemagick/update-libjpeg.sh <release>   (for example 9f)" >&2
    exit 1
fi

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGE_DIR/vendor-library.sh"

vendor_library "$PACKAGE_DIR" libjpeg "https://www.ijg.org/files/jpegsrc.v$1.tar.gz" "$1"
