#!/usr/bin/env bash
# Takes a given upstream FFmpeg version's source into vendor/ffmpeg. See update-ffmpeg.md.
set -euo pipefail

if [ $# -ne 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: third-party/ffmpeg/update-ffmpeg.sh <version>   (for example 9.0.2)" >&2
    exit 1
fi

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGE_DIR/vendor-library.sh"

# Left out: the reference output of FFmpeg's own tests, which is most of the tests directory and is read by nothing but them
# (the rest of the tests directory stays because FFmpeg's top level Makefile includes it, and the file lists of the Zig build
# are read from that Makefile), and the presets and the player, which needs SDL.
vendor_library "$PACKAGE_DIR" ffmpeg "https://ffmpeg.org/releases/ffmpeg-$1.tar.xz" "$1" \
    tests/ref presets fftools/ffplay.c fftools/ffplay_renderer.c fftools/ffplay_renderer.h

# FFmpeg's command line programs keep their state per run, so the program can run several at once on its threads (see
# update-ffmpeg.md). A version the patch no longer applies to fails here, naming the files it could not patch.
patch -p1 --forward -d "$PACKAGE_DIR/vendor/ffmpeg" < "$PACKAGE_DIR/fftools-per-run-state.patch"
