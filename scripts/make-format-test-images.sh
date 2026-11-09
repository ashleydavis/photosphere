#!/usr/bin/env bash
#
# Makes the images and videos the format tests read, into test/formats/ (gitignored, not committed).
# A file already there is kept, so this is quick after the first run. Needs ImageMagick and ffmpeg.
#
set -euo pipefail

out="$(cd "$(dirname "$0")/.." && pwd)/test/formats"
# On Windows (Git Bash) the path is given to ImageMagick and ffmpeg in its Windows form (D:/a/...). Git Bash converts a
# path that is an argument of its own, but not one behind a format prefix such as GIF:, so ImageMagick was handed
# /d/a/... and could not open it.
if command -v cygpath >/dev/null 2>&1; then
    out="$(cygpath -m "$out")"
fi
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

#
# Prints a number as the four bytes of a little-endian 32-bit field: le32 <number>.
#
le32() {
    local hex
    hex="$(printf '%08x' "$1")"
    printf "\\x${hex:6:2}\\x${hex:4:2}\\x${hex:2:2}\\x${hex:0:2}"
}

# A BMP with the 108-byte v4 header. ImageMagick 6 writes only the v2, v3 and v5 headers, so a v3 BMP (24 bits,
# uncompressed, its pixels at byte 54) is grown into one: the file size, the pixel offset and the header size go up by
# the 68 bytes the v4 header adds, which are four zero colour masks, the sRGB colour space and zero endpoints and gamma.
if [ ! -f "$out/63x35-v4.bmp" ]; then
    "${convert_tool[@]}" -size 63x35 gradient:green-white "BMP3:$out/63x35-v4.bmp.v3"
    # wc -c, not stat, which takes different flags on macOS. Its padding is stripped by the arithmetic it is used in.
    v3_size="$(wc -c < "$out/63x35-v4.bmp.v3")"
    {
        printf 'BM'
        le32 $((v3_size + 68))
        le32 0
        le32 $((54 + 68))
        le32 108
        tail -c +19 "$out/63x35-v4.bmp.v3" | head -c 36
        head -c 16 /dev/zero
        printf 'BGRs'
        head -c 48 /dev/zero
        tail -c +55 "$out/63x35-v4.bmp.v3"
    } > "$out/63x35-v4.bmp.tmp"
    rm "$out/63x35-v4.bmp.v3"
    mv "$out/63x35-v4.bmp.tmp" "$out/63x35-v4.bmp"
fi

# A HEIC laid out as an iPhone writes one, copied from the committed test picture under its size.
if [ ! -f "$out/1000x700-tiled.heic" ]; then
    cp "$out/../heic/tiled.heic" "$out/1000x700-tiled.heic"
fi

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

# The same photo in more sizes, portrait and landscape, whose pictures getImageDetails must make the same sizes with and
# without the reduced decode.
make 3648x5472-portrait.jpg JPEG -size 3648x5472 gradient:red-blue -quality 90 -strip
make 2999x4001-portrait.jpg JPEG -size 2999x4001 gradient:red-blue -quality 90 -strip
make 1111x1000.jpg JPEG -size 1111x1000 gradient:red-blue -quality 90 -strip
make 1601x1203.jpg JPEG -size 1601x1203 gradient:red-blue -quality 90 -strip

# A white picture with a black 10x10 square in its top left corner, so a flip or a turn shows where the square ends up.
make 40x30-corner-square.png PNG -size 40x30 xc:white -fill black -draw "rectangle 0,0 9,9"

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

# The other video types phones and cameras record that the import takes (its content type starts video/).
# 3GP from older phones, in H.263 (only the standard sizes, 128x96 is SQCIF) and H.264.
make_video 128x96-h263.3gp -c:v h263 -c:a aac
make_video 160x90-h264.3gp -c:v libx264 -pix_fmt yuv420p -c:a aac
# M4V, the MP4 an iPhone or iTunes names .m4v.
make_video 192x108-h264.m4v -c:v libx264 -pix_fmt yuv420p -c:a aac
# AVI from compact cameras: Motion JPEG with PCM sound, and MPEG-4 Part 2 tagged XVID.
make_video 160x120-mjpeg.avi -c:v mjpeg -pix_fmt yuvj420p -c:a pcm_s16le
make_video 176x144-mpeg4-xvid.avi -c:v mpeg4 -vtag XVID -c:a mp2
# MPEG program streams from DVD and older camcorders: MPEG-2 in .mpg and .vob, MPEG-1 in .mpeg.
make_video 208x112-mpeg2.mpg -c:v mpeg2video -c:a mp2
make_video 224x128-mpeg2.vob -c:v mpeg2video -c:a mp2 -f vob
make_video 240x144-mpeg1.mpeg -c:v mpeg1video -c:a mp2
# Matroska and WebM, from screen recorders and Android apps.
make_video 256x144-h264.mkv -c:v libx264 -pix_fmt yuv420p -c:a aac
make_video 272x160-vp9.webm -c:v libvpx-vp9 -pix_fmt yuv420p -an
make_video 288x160-vp8.webm -c:v libvpx -pix_fmt yuv420p -an
# Windows Media from older Windows phones and cameras: WMV in ASF, with WMA sound.
make_video 320x180-wmv2.wmv -c:v wmv2 -c:a wmav2 -f asf
# MS MPEG-4 v3 (DivX 3) in AVI, from older cameras and phones.
make_video 336x192-msmpeg4v3.avi -c:v msmpeg4 -c:a mp2
# DV from MiniDV camcorders, in AVI and MOV. The DV encoder takes only the standard sizes: 720x576 is PAL, at 25 frames
# a second.
make_video 720x576-dv.avi -c:v dvvideo -pix_fmt yuv420p -c:a pcm_s16le -ar 48000
make_video 720x576-dv.mov -c:v dvvideo -pix_fmt yuv420p -c:a pcm_s16le -ar 48000

# A video type the import never adds, named -not-imported so the check expects no record of it.
# AVCHD camcorders write H.264 in MPEG-TS (.mts), whose content type video/mp2t the scanner leaves out, because a
# TypeScript .ts file has the same content type.
make_video 304x176-h264-not-imported.mts -c:v libx264 -pix_fmt yuv420p -c:a aac -f mpegts

# A phone's HEIC: a 1000x700 picture stored as tiles, which the built-in FFmpeg decodes and joins.
if [ ! -f "$out/1000x700-tiled.heic" ]; then
    cp "$out/../heic/tiled.heic" "$out/1000x700-tiled.heic"
fi
echo "Format test images and videos are in $out"
