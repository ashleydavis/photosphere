#!/usr/bin/env bash
# Writes the licence files every distributed build of Photosphere carries into a directory: Photosphere's own
# licence, the third-party notices, the GNU LGPL 2.1 that FFmpeg is used under, the licence texts of the other
# bundled libraries, and a note naming the commit the build was made from and where its complete source is.
#
# The app and the CLI link FFmpeg statically, and the LGPL 2.1 (section 6) then asks that every copy says FFmpeg
# is used and is under the LGPL, comes with a copy of the LGPL, and gives the recipient the source of the whole
# program in a form they can change FFmpeg in and relink. The packaging scripts and the release workflows call
# this so that every package and archive they publish holds these files. See THIRD-PARTY-NOTICES.md.
#
# The commit is read from the checkout this script is in, so run it from the checkout the build was made from.
#
# Usage: scripts/write-licence-files.sh <directory>
#   <directory>   Where the files go. It is created if it does not exist, and files of the same names in it are
#                 replaced.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: write-licence-files.sh <directory>" >&2
    exit 1
fi
OUTPUT_DIR="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY_URL="https://github.com/ashleydavis/photosphere"
FFMPEG_DIR="$REPO_DIR/third-party/ffmpeg/vendor/ffmpeg"
IMAGEMAGICK_VENDOR_DIR="$REPO_DIR/third-party/imagemagick/vendor"

COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
FFMPEG_VERSION="$(head -n 1 "$FFMPEG_DIR/VENDORED_VERSION")"

mkdir -p "$OUTPUT_DIR"
cp "$REPO_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.txt"
cp "$REPO_DIR/THIRD-PARTY-NOTICES.md" "$OUTPUT_DIR/THIRD-PARTY-NOTICES.md"
cp "$FFMPEG_DIR/COPYING.LGPLv2.1" "$OUTPUT_DIR/COPYING.LGPLv2.1.txt"

# The licence texts the vendored libraries carry, one after another, each under the name of the file it came from. cat stops the
# script when a file is missing, so a library update that moves one fails the package rather than shipping without it.
{
    for licence_file in \
        "third-party/ffmpeg/vendor/ffmpeg/LICENSE.md" \
        "third-party/imagemagick/vendor/imagemagick/LICENSE" \
        "third-party/imagemagick/vendor/imagemagick/NOTICE" \
        "third-party/imagemagick/vendor/libjpeg/README" \
        "third-party/imagemagick/vendor/libpng/LICENSE" \
        "third-party/imagemagick/vendor/libwebp/COPYING" \
        "third-party/imagemagick/vendor/libwebp/PATENTS"; do
        echo "================================================================================"
        echo "$licence_file"
        echo "================================================================================"
        echo
        cat "$REPO_DIR/$licence_file"
        echo
    done
} > "$OUTPUT_DIR/THIRD-PARTY-LICENCES.txt"

cat > "$OUTPUT_DIR/SOURCE.txt" <<SOURCE
Photosphere source code

This build of Photosphere was made from commit $COMMIT
of $REPOSITORY_URL

Photosphere is free software under the MIT licence (LICENSE.txt). The complete source code of this build is
that commit, including the scripts that build it. It holds the source of FFmpeg, ImageMagick and
ImageMagick's delegates, and names the rest (zlib-ng, the AWS SDK for C and Ziggy) by address and hash in
its build.zig.zon files, from where the build fetches them:

    $REPOSITORY_URL/tree/$COMMIT
    $REPOSITORY_URL/archive/$COMMIT.tar.gz

FFmpeg

This build links FFmpeg $FFMPEG_VERSION statically. FFmpeg is free software under the GNU Lesser General Public
License, version 2.1 or later (COPYING.LGPLv2.1.txt), and is copyright the FFmpeg project and contributors
(https://ffmpeg.org/). It is built without --enable-gpl and without --enable-nonfree.

- FFmpeg's source is in third-party/ffmpeg/vendor/ffmpeg at the commit above: the release archive named
  in VENDORED_VERSION there, with some of its tests, presets and player left out, and with
  third-party/ffmpeg/fftools-per-run-state.patch applied to the ffmpeg and ffprobe programs (fftools).
  Each file the patch changes says so at its top. Nothing else in FFmpeg is changed.
- The configure options it is built with are in third-party/ffmpeg/generate-config.sh, and the exact
  configure command line for each target is recorded as FFMPEG_CONFIGURATION in
  third-party/ffmpeg/config/<target>/config.h.
- It is compiled by third-party/ffmpeg/build.zig.

To run this program with a modified FFmpeg, check out the commit above, change the source under
third-party/ffmpeg/vendor/ffmpeg, delete third-party/ffmpeg/zig-out so the library is compiled again, and
build Photosphere as README.md and apps/photosphere/README.md describe. The build compiles FFmpeg from that
source and links the program against it.

THIRD-PARTY-NOTICES.md lists every bundled library and its licence, and THIRD-PARTY-LICENCES.txt holds the
licence texts that come with the vendored libraries.
SOURCE

echo "Wrote the licence files for commit $COMMIT to $OUTPUT_DIR"
