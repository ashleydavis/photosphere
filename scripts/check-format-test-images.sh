#!/usr/bin/env bash
#
# Imports every image and video made by scripts/make-format-test-images.sh into a new database with the built psi, then checks
# the width and height psi recorded for each against the size in its file name. A JPEG whose EXIF Orientation is 6 or
# 8 is turned a quarter, so its recorded size is the file name's swapped. It also checks the import stored a JPEG thumbnail of
# each (made from a screenshot, for a video) and a JPEG display picture of each image, that no file named -not-imported
# was imported, that types the ImageMagick security policy does not allow are refused, and that each image's display,
# thumbnail and micro copies are sRGB, with no colour profile, in the image's own colours. Exits 1 naming each file or
# type that is wrong. Each thumbnail must also have its file's shape.
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

    # The thumbnail must also have the file's shape. psi info names a file's type from its extension, so the thumbnail is
    # read through a copy named .jpg.
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
    echo "ok    $name: $recorded, with a JPEG $pictures, thumbnail $thumbSize"
done

if [ "$failures" -ne 0 ]; then
    echo "$failures file(s) failed the check" >&2
    exit 1
fi
echo "Every image and video recorded with the right size and its pictures, and no -not-imported file imported"

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

#
# The display, thumbnail and micro copies psi makes of each image must be sRGB with no colour profile, and the same colour
# as the image shown through its own profile: for a file with a colour profile, ImageMagick's conversion of it into sRGB
# with the sRGB profile ImageMagick ships, and for a file with none, its pixels as they are. Videos are only size checked,
# a -not-imported file has no copies, and a HEIC is skipped because the ImageMagick on the machine cannot read one to give
# its reference colour.
# These reference colours come from the ImageMagick installed on the machine, which only this part of the check runs.
#
if command -v magick >/dev/null 2>&1; then
    image_tool=(magick)
else
    image_tool=(convert)
fi
srgb_profile="$root/third-party/imagemagick/vendor/imagemagick/config/sRGB.icm"

#
# Prints the mean colour of a picture's first frame as three whole numbers from 0 to 255: mean_colour <file> [ImageMagick arguments].
#
mean_colour() {
    local file="$1"
    shift
    "${image_tool[@]}" "$file[0]" "$@" -format '%[fx:int(255*mean.r+0.5)] %[fx:int(255*mean.g+0.5)] %[fx:int(255*mean.b+0.5)]' info:
}

#
# Checks one copy psi made: check_copy <image name> <copy kind> <copy file> <expected mean colour>. The colour may be 3 off
# in each channel, for the JPEG compression and the resize of a copy; the conversion of each image with a profile moves
# its colour much further than that.
#
check_copy() {
    local name="$1"
    local kind="$2"
    local copy="$3"
    local expected="$4"
    if [ ! -s "$copy" ]; then
        echo "FAIL  $name $kind: psi made no $kind copy"
        return 1
    fi
    # ImageMagick writes a picture with no colour in it (the white to black WebP) as a one channel Gray JPEG, which a viewer
    # shows as the sRGB greys; the mean colour below still compares all three channels.
    local colourspace
    colourspace="$("${image_tool[@]}" "$copy" -format '%[colorspace]' info:)"
    if [ "$colourspace" != "sRGB" ] && [ "$colourspace" != "Gray" ]; then
        echo "FAIL  $name $kind: the copy is $colourspace, not sRGB or Gray"
        return 1
    fi
    if "${image_tool[@]}" "$copy" icc:- > /dev/null 2>&1; then
        echo "FAIL  $name $kind: the copy still carries a colour profile"
        return 1
    fi
    local actual
    actual="$(mean_colour "$copy")"
    local expectedChannels=($expected)
    local actualChannels=($actual)
    local channel
    for channel in 0 1 2; do
        local difference=$((actualChannels[channel] - expectedChannels[channel]))
        if [ "$difference" -gt 3 ] || [ "$difference" -lt -3 ]; then
            echo "FAIL  $name $kind: mean colour $actual, expected $expected"
            return 1
        fi
    done
    echo "ok    $name $kind: $colourspace, no profile, mean colour $actual (expected $expected)"
}

colourFailures=0
for file in "$formats"/*; do
    name="$(basename "$file")"
    case "$name" in
        *.mp4|*.mov|*.m4v|*.3gp|*.mkv|*.webm|*.avi|*.mpg|*.mpeg|*.vob|*.wmv|*.mts|*-not-imported.*|*.heic)
            continue
            ;;
    esac

    if "${image_tool[@]}" "$file[0]" icc:- > /dev/null 2>&1; then
        expected="$(mean_colour "$file" -profile "$srgb_profile")"
    else
        expected="$(mean_colour "$file")"
    fi

    # A database of its own for each image, so the display and thumb directories and the micro thumbnail held in the
    # metadata all belong to it.
    db="$work/colour/$name"
    mkdir -p "$db"
    PATH="$no_tools" "$psi" init --db "$db" --yes > "$work/colour/$name.log" 2>&1
    PATH="$no_tools" "$psi" add --db "$db" --yes "$file" >> "$work/colour/$name.log" 2>&1 || {
        echo "FAIL  $name: psi add failed: $work/colour/$name.log"
        colourFailures=$((colourFailures + 1))
        continue
    }
    check_copy "$name" display "$(ls -d "$db"/display/* | head -n 1)" "$expected" || colourFailures=$((colourFailures + 1))
    check_copy "$name" thumb "$(ls -d "$db"/thumb/* | head -n 1)" "$expected" || colourFailures=$((colourFailures + 1))

    # The micro thumbnail is a base64 JPEG in the asset's record (and again in the import record), so it is the one
    # string of the database's files that starts with the base64 of a JPEG's first bytes, /9j/.
    micros="$(find "$db" -type f ! -path "$db/display/*" ! -path "$db/thumb/*" ! -path "$db/asset/*" -exec cat {} + | tr '\0' '\n' | LC_ALL=C grep -ao '/9j/[A-Za-z0-9+/=]*' | sort -u)"
    if [ "$(printf '%s\n' "$micros" | grep -c .)" -ne 1 ]; then
        echo "FAIL  $name micro: expected one micro thumbnail in the database, found: $micros"
        colourFailures=$((colourFailures + 1))
        continue
    fi
    printf '%s' "$micros" | base64 -d > "$work/colour/$name.micro.jpg"
    check_copy "$name" micro "$work/colour/$name.micro.jpg" "$expected" || colourFailures=$((colourFailures + 1))
done

if [ "$colourFailures" -ne 0 ]; then
    echo "$colourFailures image copies with the wrong colour" >&2
    exit 1
fi
echo "Every image's display, thumbnail and micro copies are sRGB with the right colour"
