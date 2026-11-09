# check-format-test-images.sh

Imports every image and video in `test/formats/` into a new database with the built `psi`, then checks the width and height
`psi` recorded for each against the size at the start of its file name (`53x31-alpha.png` must be 53 × 31). A JPEG
with an EXIF Orientation of 6 or 8 stands upright when turned, so it must be recorded with the size swapped.

Both the import and `psi info <file>` read each image's EXIF as well as its size, and a failed EXIF read is an error, not
an image with no date. So every file, including the JPEGs with no EXIF or a broken EXIF segment, must import, and a file
`psi info` could not read is reported with the error it printed, which for an EXIF read names the `identify` command and
the file.

For each file it also checks the pictures the import made: a thumbnail and a display picture for an image, a thumbnail
for a video, each in the database under `thumb/<asset id>` and `display/<asset id>` and each starting with the JPEG
start-of-image marker. The built-in ImageMagick writes every one of them (a video's from the frame FFmpeg takes, a HEIC's
from the JPEG FFmpeg decodes it into), so a type it can no longer read or write shows here.

Last it writes an SVG, a PostScript file and a portable pixmap, named `.png` or `.jpg` so the import hands them to
ImageMagick, imports them into a second database and checks that each was refused with ImageMagick's `NotAuthorized`
error naming its coder and that none was added. ImageMagick picks the coder from the file's first bytes, so this is
the security policy in `packages-zig/media-tools-zig/src/lib/image-magick.zig` refusing every type it does not allow.

Every `psi` command runs with a `PATH` that is a single empty directory, so each file is read by the ImageMagick and
FFmpeg built into `psi`, never by a `magick`, `ffmpeg` or `ffprobe` installed on the machine.

```
bun run build:cli
bash scripts/make-format-test-images.sh
bash scripts/check-format-test-images.sh [psi executable]
```

- `psi executable`: optional, defaults to `zig-out/bin/psi`. The script does not build it.

Prints `ok` or `FAIL` per image and per refused type, and exits 1 if any image failed to import, was recorded with the
wrong size or is missing a picture, or if a type outside the policy was not refused. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
