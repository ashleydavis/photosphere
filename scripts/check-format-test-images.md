# check-format-test-images.sh

Imports every image and video in `test/formats/` into a new database with the built `psi`, then checks the width and height
`psi` recorded for each against the size at the start of its file name (`53x31-alpha.png` must be 53 × 31). A JPEG
with an EXIF Orientation of 6 or 8 stands upright when turned, so it must be recorded with the size swapped.

Both the import and `psi info <file>` read each image's EXIF as well as its size, and a failed EXIF read is an error, not
an image with no date. So every file, including the JPEGs with no EXIF or a broken EXIF segment, must import, and a file
`psi info` could not read is reported with the error it printed, which for an EXIF read names the `identify` command and
the file.

Each file must also have a thumbnail in the database (`thumb/<asset id>`): for an image ImageMagick resizes it, and for
a video FFmpeg takes a screenshot that ImageMagick then resizes, so this is where a broken FFmpeg or ImageMagick call
shows for a video. The thumbnail must start with the JPEG marker, the built-in ImageMagick must read a size from it
(`psi info` on a `.jpg` copy), and that size must have the shape of the recorded size, to within the rounding of a side
to a whole pixel, so a thumbnail turned the wrong way fails. The micro picture is made from the thumbnail and a failure
to read it fails the import, so it shows here as a file with no recorded size.

Every `psi` command runs with a `PATH` that is a single empty directory, so each file is read by the ImageMagick and
FFmpeg built into `psi`, never by a `magick`, `ffmpeg` or `ffprobe` installed on the machine.

```
bun run build:cli
bash scripts/make-format-test-images.sh
bash scripts/check-format-test-images.sh [psi executable]
```

- `psi executable`: optional, defaults to `zig-out/bin/psi`. The script does not build it.

Prints `ok` or `FAIL` per file and exits 1 if any file failed to import, was recorded with the wrong size, or has no good thumbnail. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
