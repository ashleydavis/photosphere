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

# Video types the import never adds, named -not-imported so the check expects no record of them.
# AVCHD camcorders write H.264 in MPEG-TS (.mts), whose content type video/mp2t the scanner leaves out, because a
# TypeScript .ts file has the same content type.
make_video 304x176-h264-not-imported.mts -c:v libx264 -pix_fmt yuv420p -c:a aac -f mpegts
# Windows Media (ASF holding WMV), which the built-in FFmpeg is not built to read: the import refuses it.
make_video 320x180-wmv2-not-imported.wmv -c:v wmv2 -c:a mp2 -f asf

# A phone's HEIC: a 1000x700 picture stored as tiles, which the built-in FFmpeg decodes and joins.
if [ ! -f "$out/1000x700-tiled.heic" ]; then
    cp "$out/../heic/tiled.heic" "$out/1000x700-tiled.heic"
fi
echo "Format test images and videos are in $out"
