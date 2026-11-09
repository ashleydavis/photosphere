#!/usr/bin/env bash
#
# Imports every image and video made by scripts/make-format-test-images.sh into a new database with the built psi, then checks
# the width and height psi recorded for each against the size in its file name. A JPEG whose EXIF Orientation is 6 or
# 8 is turned a quarter, so its recorded size is the file name's swapped. It also checks the import stored a JPEG thumbnail of
# each (made from a screenshot, for a video) and a JPEG display picture of each image, and that no file named -not-imported
# was imported. Exits 1 naming each file that is wrong.
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

    # A file named -not-imported is a type the import never adds, so the database must hold no asset of that name.
    case "$name" in
        *-not-imported.*)
            if PATH="$no_tools" "$psi" list --db "$work/db" --yes --page-size 100000 2>&1 | grep -qF "$name"; then
                echo "FAIL  $name: imported, but this type must not be"
                failures=$((failures + 1))
            else
                echo "ok    $name: not imported"
            fi
            continue
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
    assetInfo="$(PATH="$no_tools" "$psi" info --db "$work/db" "$hash")"
    recorded="$(printf '%s\n' "$assetInfo" | sed -n 's/^ *Dimensions: //p')"
    expected="$width × $height"
    if [ "$recorded" != "$expected" ]; then
        echo "FAIL  $name: expected $expected, recorded '$recorded'"
        failures=$((failures + 1))
        continue
    fi

    # The import made a thumbnail of it, from a screenshot for a video, and a display picture of an image, each a JPEG:
    # a file that starts with the JPEG start-of-image marker FF D8 FF. A video has no display picture.
    assetId="$(printf '%s\n' "$assetInfo" | sed -n 's/^ *Asset ID: //p')"
    case "$(printf '%s\n' "$assetInfo" | sed -n 's/^ *Type: //p')" in
        video/*)
            pictures="thumb"
            ;;
        *)
            pictures="thumb display"
            ;;
    esac
    missing=""
    for kind in $pictures; do
        if [ "$(od -An -tx1 -N3 "$work/db/$kind/$assetId" 2>/dev/null | tr -d ' ')" != "ffd8ff" ]; then
            missing="$missing $kind"
        fi
    done
    if [ -n "$missing" ]; then
        echo "FAIL  $name: $recorded, but no JPEG$missing in the database"
        failures=$((failures + 1))
        continue
    fi
    echo "ok    $name: $recorded, with a JPEG $pictures"
done

if [ "$failures" -ne 0 ]; then
    echo "$failures file(s) failed the check" >&2
    exit 1
fi
echo "Every image and video recorded with the right size and its pictures, and no -not-imported file imported"
