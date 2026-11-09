#!/usr/bin/env bash
#
# Imports every image and video made by scripts/make-format-test-images.sh into a new database with the built psi, then checks
# the width and height psi recorded for each against the size in its file name. A JPEG whose EXIF Orientation is 6 or
# 8 is turned a quarter, so its recorded size is the file name's swapped. Then checks the import made each a JPEG thumbnail of
# the same shape, which for a video is a frame FFmpeg decoded. Exits 1 naming each image that is wrong.
# psi runs with a PATH that holds nothing, so every file is read by the ImageMagick and FFmpeg built into psi and never by
# a magick, ffmpeg or ffprobe installed on the machine.
#
# Arguments: [psi executable], default zig-out/bin/psi. It is not built here: build it first with `bun run build:cli`.
#
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
psi="${1:-$root/zig-out/bin/psi}"
formats="$root/test/formats"

if [ ! -x "$psi" ]; then
    echo "No psi at $psi: build it with bun run build:cli" >&2
    exit 1
fi
# psi is run below with an empty PATH, so it is named by its full path.
psi="$(cd "$(dirname "$psi")" && pwd)/$(basename "$psi")"
if [ -z "$(ls -A "$formats" 2>/dev/null)" ]; then
    echo "No images in $formats: make them with bash scripts/make-format-test-images.sh" >&2
    exit 1
fi

# A new directory each run, so two runs never share a database. It is left behind for inspection.
work="$(mktemp -d)"
echo "Database: $work/db"
# An empty directory as the whole PATH: no magick, ffmpeg or ffprobe can be found on it.
no_tools="$work/no-tools-path"
mkdir "$no_tools"
# Copies of the thumbnails, named so psi info can read them.
thumbs="$work/thumbs"
mkdir "$thumbs"
PATH="$no_tools" "$psi" init --db "$work/db" --yes > "$work/init.log" 2>&1 || {
    cat "$work/init.log" >&2
    exit 1
}
# A file that fails to import is not fatal here: it has no recorded size, so the check below reports it by name.
PATH="$no_tools" "$psi" add --db "$work/db" --yes "$formats" > "$work/add.log" 2>&1 || {
    echo "psi add reported a failure: $work/add.log"
}

failures=0
for file in "$formats"/*; do
    name="$(basename "$file")"

    # The expected size is the leading <width>x<height> of the file name.
    size="${name%%[-.]*}"
    width="${size%x*}"
    height="${size#*x}"
    case "$name" in
        *-exif-orientation-6.*|*-exif-orientation-8.*)
            swapped="$width"
            width="$height"
            height="$swapped"
            ;;
    esac

    # psi info reads the file's size and its EXIF, and prints the error instead of a hash when either read fails.
    fileInfo="$(PATH="$no_tools" "$psi" info "$file")"
    hash="$(printf '%s\n' "$fileInfo" | sed -n 's/^ *Hash: //p')"
    # psi info with no hash would list the current directory, so a file psi could not read is reported as not imported.
    if [ -z "$hash" ]; then
        echo "FAIL  $name: psi could not read it: $(printf '%s\n' "$fileInfo" | sed -n 's/^ *Error: //p')"
        failures=$((failures + 1))
        continue
    fi
    recordedInfo="$(PATH="$no_tools" "$psi" info --db "$work/db" "$hash")"
    recorded="$(printf '%s\n' "$recordedInfo" | sed -n 's/^ *Dimensions: //p')"
    expected="$width × $height"
    if [ "$recorded" != "$expected" ]; then
        echo "FAIL  $name: expected $expected, recorded '$recorded'"
        failures=$((failures + 1))
        continue
    fi

    # The import made a thumbnail from the image, or for a video from a frame FFmpeg decoded, so it must be a JPEG with the
    # image's shape. psi info names a file's type from its extension, so the thumbnail is read through a copy named .jpg.
    assetId="$(printf '%s\n' "$recordedInfo" | sed -n 's/^ *Asset ID: //p')"
    if [ ! -f "$work/db/thumb/$assetId" ]; then
        echo "FAIL  $name: the import made no thumbnail"
        failures=$((failures + 1))
        continue
    fi
    cp "$work/db/thumb/$assetId" "$thumbs/$name.jpg"
    thumbInfo="$(PATH="$no_tools" "$psi" info "$thumbs/$name.jpg")"
    thumbType="$(printf '%s\n' "$thumbInfo" | sed -n 's/^ *Type: //p')"
    thumbSize="$(printf '%s\n' "$thumbInfo" | sed -n 's/^ *Dimensions: //p')"
    if [ "$thumbType" != "image/jpeg" ] || [ -z "$thumbSize" ]; then
        echo "FAIL  $name: thumbnail is '$thumbType' '$thumbSize', not a JPEG psi can read"
        failures=$((failures + 1))
        continue
    fi
    thumbWidth="${thumbSize%% ×*}"
    thumbHeight="${thumbSize##*× }"
    # The thumbnail's sides are whole pixels, so its shape may differ from the image's by the rounding of one side: up to one
    # pixel of the thumbnail on the image's shorter side.
    shapeDifference=$((thumbWidth * height - thumbHeight * width))
    shapeDifference="${shapeDifference#-}"
    shorterSide=$((width < height ? width : height))
    if [ "$shapeDifference" -gt "$shorterSide" ]; then
        echo "FAIL  $name: thumbnail is $thumbSize, not the shape of $expected"
        failures=$((failures + 1))
        continue
    fi
    echo "ok    $name: $recorded, thumbnail $thumbSize"
done

if [ "$failures" -ne 0 ]; then
    echo "$failures image(s) recorded with the wrong size or thumbnail" >&2
    exit 1
fi
echo "Every image recorded with the right size and thumbnail"
