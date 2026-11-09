#!/usr/bin/env bash
# Takes a given upstream Little CMS 2 (lcms2) version's source into vendor/lcms2. See update-lcms2.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: third-party/imagemagick/update-lcms2.sh <version>   (for example 2.20)" >&2
    exit 1
fi

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGE_DIR/vendor-library.sh"

# Left out: the documentation, the test profiles and programs, the command line utilities, the plugins, the fuzzers and the
# projects of other build systems.
vendor_library "$PACKAGE_DIR" lcms2 "https://github.com/mm2/Little-CMS/releases/download/lcms$1/lcms2-$1.tar.gz" "$1" \
    doc testbed utils plugins fuzzers Projects Lib bin .github .gitignore
