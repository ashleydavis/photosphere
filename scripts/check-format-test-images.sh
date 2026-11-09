#!/usr/bin/env bash
#
# Imports every image and video made by scripts/make-format-test-images.sh into a new database with the built psi, then checks
# the width and height psi recorded for each against the size in its file name. A JPEG whose EXIF Orientation is 6 or
# 8 is turned a quarter, so its recorded size is the file name's swapped. It checks each has its JPEG thumbnail (and,
# for an image, display picture) in the database, and that types the ImageMagick security policy does not allow are
# refused. Exits 1 naming each image or type that is wrong.
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
    assetId="$(printf '%s\n' "$assetInfo" | sed -n 's/^ *Asset ID: //p')"
    expected="$width × $height"

    # The thumbnail and, for an image, the display picture are JPEGs the built-in ImageMagick wrote (for a video, from the
    # frame FFmpeg took), so each must be in the database and start with the JPEG start-of-image marker.
    case "$name" in
        *.mp4|*.mov)
            pictures="thumb"
            ;;
        *)
            pictures="thumb display"
            ;;
    esac
    missing=""
    for picture in $pictures; do
        if [ -z "$assetId" ] || [ "$(od -A n -t x1 -N 3 "$work/db/$picture/$assetId" 2>/dev/null | tr -d ' ')" != "ffd8ff" ]; then
            missing="$missing $picture"
        fi
    done

    if [ -n "$missing" ]; then
        echo "FAIL  $name: no JPEG$missing picture in the database for asset '$assetId'"
        failures=$((failures + 1))
    elif [ "$recorded" = "$expected" ]; then
        echo "ok    $name: $recorded, $pictures"
    else
        echo "FAIL  $name: expected $expected, recorded '$recorded'"
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures image(s) not imported, recorded with the wrong size or missing a picture" >&2
    exit 1
fi
echo "Every image recorded with the right size and its pictures"

# The built-in ImageMagick reads only JPEG, PNG, WebP, GIF and BMP, and picks the coder from a file's first bytes, not its
# name. So an SVG, a PostScript file and a portable pixmap named as images the program takes must each be refused with
# ImageMagick's NotAuthorized error naming the coder, and none of them may import.
refused="$work/refused"
mkdir "$refused"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"/></svg>\n' > "$refused/svg.png"
printf '%%!PS-Adobe-3.0\nnewpath 0 0 moveto 20 0 lineto 20 10 lineto closepath fill showpage\n' > "$refused/ps.jpg"
printf 'P3\n3 2\n255\n255 0 0 0 255 0 0 0 255 255 255 0 255 255 255 0 0 0\n' > "$refused/ppm.png"
PATH="$no_tools" "$psi" init --db "$work/refused-db" --yes > "$work/refused-init.log" 2>&1 || {
    cat "$work/refused-init.log" >&2
    exit 1
}
# The import is expected to fail for every file, so its exit code is not the check: what it printed is.
PATH="$no_tools" "$psi" add --db "$work/refused-db" --yes "$refused" > "$work/refused-add.log" 2>&1 || true
for coder in SVG PS PPM; do
    if grep -q "NotAuthorized \`$coder'" "$work/refused-add.log"; then
        echo "ok    $coder refused: NotAuthorized"
    else
        echo "FAIL  $coder was not refused with NotAuthorized: $work/refused-add.log"
        failures=$((failures + 1))
    fi
done
if grep -q "^Files added: *0$" "$work/refused-add.log"; then
    echo "ok    no refused file imported"
else
    echo "FAIL  a refused file was imported: $(grep "^Files added:" "$work/refused-add.log")"
    failures=$((failures + 1))
fi
if [ "$failures" -ne 0 ]; then
    echo "$failures refused type(s) were not refused" >&2
    exit 1
fi
echo "Every type outside the policy refused"
