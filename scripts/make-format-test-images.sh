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
# Pictures carrying a colour profile that is not sRGB, which psi must convert into sRGB before it strips the profile from
# the display, thumbnail and micro copies. Each is one solid colour, so the check can compare a copy's colour with
# ImageMagick's own sRGB conversion of the file however the copy was resized.
#
# No wide gamut RGB profile ships with ImageMagick or this repository, so one is written here byte by byte: an ICC v2
# display profile with the Display P3 primaries and white point (adapted to D50, as Apple's Display P3 profile gives them)
# and a plain 2.2 gamma curve, 432 bytes. Layout: the 128 byte header, a table of 8 tags, then the tags' data
# (description, white point, the three primaries, and one curve the three TRC tags share).
#
# ImageMagick takes a profile by the extension of its file name, so the file is named .icc in a directory of its own.
p3_directory="$(mktemp -d)"
p3_profile="$p3_directory/display-p3.icc"
zeros() {
    head -c "$1" /dev/zero
}
{
    # Header: size 432, no CMM, version 2.1, display class, RGB data, XYZ connection space, no date.
    printf '\x00\x00\x01\xb0'
    zeros 4
    printf '\x02\x10\x00\x00mntrRGB XYZ '
    zeros 12
    # The signature, then platform, flags, manufacturer, model, attributes and rendering intent, all zero.
    printf 'acsp'
    zeros 28
    # The D50 illuminant (0.9642, 1.0, 0.8249), then creator, profile ID and the reserved bytes, all zero.
    printf '\x00\x00\xf6\xd6\x00\x01\x00\x00\x00\x00\xd3\x2d'
    zeros 48
    # Tag table: 8 tags, each a signature, an offset and a size.
    printf '\x00\x00\x00\x08'
    printf 'desc\x00\x00\x00\xe4\x00\x00\x00\x6a'
    printf 'wtpt\x00\x00\x01\x50\x00\x00\x00\x14'
    printf 'rXYZ\x00\x00\x01\x64\x00\x00\x00\x14'
    printf 'gXYZ\x00\x00\x01\x78\x00\x00\x00\x14'
    printf 'bXYZ\x00\x00\x01\x8c\x00\x00\x00\x14'
    printf 'rTRC\x00\x00\x01\xa0\x00\x00\x00\x0e'
    printf 'gTRC\x00\x00\x01\xa0\x00\x00\x00\x0e'
    printf 'bTRC\x00\x00\x01\xa0\x00\x00\x00\x0e'
    # desc at 228: "Display P3 g2.2" and its terminating zero (16 bytes), empty Unicode and ScriptCode parts, padded to 4.
    printf 'desc'
    zeros 4
    printf '\x00\x00\x00\x10Display P3 g2.2\x00'
    zeros 80
    # wtpt at 336: D50. Then the red, green and blue primaries, each X, Y, Z as s15Fixed16 numbers:
    # red 0.5151 0.2412 -0.0010, green 0.2920 0.6922 0.0419, blue 0.1572 0.0666 0.7841.
    printf 'XYZ \x00\x00\x00\x00\x00\x00\xf6\xd6\x00\x01\x00\x00\x00\x00\xd3\x2d'
    printf 'XYZ \x00\x00\x00\x00\x00\x00\x83\xde\x00\x00\x3d\xbf\xff\xff\xff\xbb'
    printf 'XYZ \x00\x00\x00\x00\x00\x00\x4a\xbe\x00\x00\xb1\x37\x00\x00\x0a\xb9'
    printf 'XYZ \x00\x00\x00\x00\x00\x00\x28\x3b\x00\x00\x11\x0a\x00\x00\xc8\xb9'
    # The curve at 416: one entry, a gamma of 2.2 as u8Fixed8 (0x0233), padded to 4.
    printf 'curv\x00\x00\x00\x00\x00\x00\x00\x01\x02\x33\x00\x00'
} > "$p3_profile"

# The same colour as a PNG and a JPEG, with the Display P3 profile attached to the pixels as they are (no conversion).
make 73x41-display-p3.png PNG24 -size 73x41 'xc:rgb(200,70,60)' -profile "$p3_profile"
make 79x45-display-p3.jpg JPEG -size 79x45 'xc:rgb(60,170,90)' -quality 95 -profile "$p3_profile"
rm -f "$p3_profile"
rmdir "$p3_directory"

# A CMYK JPEG carrying the CMYK profile ImageMagick ships: an sRGB colour converted into it by that profile.
icc="$(cd "$(dirname "$0")/.." && pwd)/third-party/imagemagick/vendor/imagemagick/config"
make 83x47-cmyk.jpg JPEG -size 83x47 'xc:rgb(90,120,200)' -profile "$icc/sRGB.icm" -profile "$icc/cmyk.icm" -quality 95

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
