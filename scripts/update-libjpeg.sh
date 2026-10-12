#!/usr/bin/env bash
# Takes a given upstream Independent JPEG Group libjpeg release into vendor/libjpeg. See update-libjpeg.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: scripts/update-libjpeg.sh <release>   (for example 9f)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/vendor-library.sh"

vendor_library "$REPO_ROOT" libjpeg "https://www.ijg.org/files/jpegsrc.v$1.tar.gz" "$1"
