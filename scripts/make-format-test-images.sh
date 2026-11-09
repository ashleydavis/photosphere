#!/usr/bin/env bash
#
# Makes the images the format tests read, into test/formats/ (gitignored, not committed).
# An image already there is kept, so this is quick after the first run. Needs ImageMagick.
#
set -euo pipefail

out="$(cd "$(dirname "$0")/.." && pwd)/test/formats"
mkdir -p "$out"

if command -v magick >/dev/null 2>&1; then
    convert_tool=(magick)
else
    convert_tool=(convert)
fi

#
# Makes one image unless it is already there: make <file name> <ImageMagick output format> <ImageMagick arguments>.
#
make() {
    local name="$1"
    local format="$2"
    shift 2
    if [ ! -f "$out/$name" ]; then
        "${convert_tool[@]}" "$@" "$format:$out/$name.tmp"
        mv "$out/$name.tmp" "$out/$name"
    fi
}

# One or more of each format, each width and height different so a size read the wrong way round shows.
make 37x23.gif GIF -size 37x23 gradient:red-blue
make 29x57.gif GIF -size 29x57 gradient:red-white
make 41x29.bmp BMP -size 41x29 gradient:blue-green
make 59x33-v3.bmp BMP3 -size 59x33 gradient:blue-white
make 53x31-alpha.png PNG32 -size 53x31 gradient:red-blue
make 61x43-lossless.webp WEBP -size 61x43 gradient:green-yellow -define webp:lossless=true
make 67x47-lossy.webp WEBP -size 67x47 gradient:white-black -quality 60
make 47x19-no-exif.jpg JPEG -size 47x19 gradient:red-green -strip

# Animated GIF: three frames.
make 43x17-animated.gif GIF -delay 10 -size 43x17 xc:red -size 43x17 xc:green -size 43x17 xc:blue -loop 0

# A 71x37 JPEG for each EXIF Orientation given. ImageMagick does not write an Orientation tag into a JPEG
# that has no EXIF, so a minimal EXIF segment holding only that tag is put straight after the JPEG's
# start marker: APP1, "Exif", a little-endian TIFF header, and one IFD entry (0x0112, SHORT, the value).
make 71x37-base.jpg JPEG -size 71x37 gradient:red-blue -strip
for orientation in 1 3 6 8; do
    name="71x37-exif-orientation-$orientation.jpg"
    if [ ! -f "$out/$name" ]; then
        {
            head -c 2 "$out/71x37-base.jpg"
            printf '\xff\xe1\x00\x22Exif\x00\x00II*\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00'
            printf "\\x0$orientation"
            printf '\x00\x00\x00\x00\x00\x00\x00'
            tail -c +3 "$out/71x37-base.jpg"
        } > "$out/$name.tmp"
        mv "$out/$name.tmp" "$out/$name"
    fi
done

echo "Format test images are in $out"
