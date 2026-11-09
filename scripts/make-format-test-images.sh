#!/usr/bin/env bash
#
# Makes the images and videos the format tests read, into test/formats/ (gitignored, not committed).
# A file already there is kept, so this is quick after the first run. Needs ImageMagick and ffmpeg.
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

# The same JPEG with each EXIF Orientation given: make_oriented <base JPEG file name> <orientation>...
# ImageMagick does not write an Orientation tag into a JPEG that has no EXIF, so a minimal EXIF segment
# holding only that tag is put straight after the JPEG's start marker: APP1, "Exif", a little-endian
# TIFF header, and one IFD entry (0x0112, SHORT, the value). Each is named <base size>-exif-orientation-<n>.jpg.
#
make_oriented() {
    local base="$1"
    shift
    local orientation
    for orientation in "$@"; do
        local name="${base%%-*}-exif-orientation-$orientation.jpg"
        if [ ! -f "$out/$name" ]; then
            {
                head -c 2 "$out/$base"
                printf '\xff\xe1\x00\x22Exif\x00\x00II*\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00'
                printf "\\x0$orientation"
                printf '\x00\x00\x00\x00\x00\x00\x00'
                tail -c +3 "$out/$base"
            } > "$out/$name.tmp"
            mv "$out/$name.tmp" "$out/$name"
        fi
    done
}

make 71x37-base.jpg JPEG -size 71x37 gradient:red-blue -strip
make_oriented 71x37-base.jpg 1 3 6 8

# Large JPEGs, which the display, thumbnail and micro pictures are made from by decoding them at a reduced size.
# A 20 megapixel camera's photo, and a photo whose sides are not multiples of 8, so the reduced decode rounds
# its sides up, with each EXIF Orientation. Red at the top and blue at the bottom, so a picture the wrong way
# up or turned the wrong way shows.
make 5472x3648-camera.jpg JPEG -size 5472x3648 gradient:red-blue -quality 90 -strip
make 4001x2999-base.jpg JPEG -size 4001x2999 gradient:red-blue -quality 90 -strip
make_oriented 4001x2999-base.jpg 1 3 6 8

#
# Makes the 71x37 JPEG with a broken EXIF segment unless it is already there: broken_exif <file name> <segment>.
# The segment is a printf format string, put straight after the JPEG's start marker as above. ImageMagick still
# reads the image and its EXIF identify still succeeds, so each must import with its size.
#
broken_exif() {
    local name="$1"
    if [ ! -f "$out/$name" ]; then
        {
            head -c 2 "$out/71x37-base.jpg"
            printf "$2"
            tail -c +3 "$out/71x37-base.jpg"
        } > "$out/$name.tmp"
        mv "$out/$name.tmp" "$out/$name"
    fi
}

# The IFD claims 65535 entries where it holds one.
broken_exif 71x37-exif-bad-count.jpg '\xff\xe1\x00\x22Exif\x00\x00II*\x00\x08\x00\x00\x00\xff\xff\x12\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00'
# The IFD offset points far past the end of the segment.
broken_exif 71x37-exif-bad-offset.jpg '\xff\xe1\x00\x22Exif\x00\x00II*\x00\xff\xff\xff\x7f\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00'
# The TIFF header names no byte order ("XX" where "II" or "MM" belongs).
broken_exif 71x37-exif-bad-header.jpg '\xff\xe1\x00\x22Exif\x00\x00XX*\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00'


#
# Makes one two-second video unless it is already there: make_video <file name> <ffmpeg output arguments>.
# A test pattern with a moving element and a tone, so a screenshot at any moment has something in it.
#
make_video() {
    local name="$1"
    shift
    if [ ! -f "$out/$name" ]; then
        local size="${name%%-*}"
        ffmpeg -v error -y -f lavfi -i "testsrc2=size=$size:rate=25:duration=2" -f lavfi -i "sine=frequency=440:duration=2" -shortest "$@" "$out/$name.tmp.${name##*.}"
        mv "$out/$name.tmp.${name##*.}" "$out/$name"
    fi
}

# The video types the program takes, in the codecs phones record them in. Needs ffmpeg with libx264 and libx265.
make_video 96x54-h264.mp4 -c:v libx264 -pix_fmt yuv420p -c:a aac
make_video 112x64-hevc.mp4 -c:v libx265 -x265-params log-level=error -tag:v hvc1 -pix_fmt yuv420p -c:a aac
make_video 128x72-h264.mov -c:v libx264 -pix_fmt yuv420p -c:a aac
make_video 144x80-hevc.mov -c:v libx265 -x265-params log-level=error -tag:v hvc1 -pix_fmt yuv420p -c:a aac
echo "Format test images and videos are in $out"
