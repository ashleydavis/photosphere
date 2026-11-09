# check-format-test-images.sh

Imports every image and video in `test/formats/` into a new database with the built `psi`, then checks the width and height
`psi` recorded for each against the size at the start of its file name (`53x31-alpha.png` must be 53 × 31). A JPEG
with an EXIF Orientation of 6 or 8 stands upright when turned, so it must be recorded with the size swapped.

It then checks that the import made each file a thumbnail that is a JPEG of the same shape as the recorded size, allowing
for the rounding of one side to whole pixels. A video's thumbnail is made from a frame the FFmpeg built into `psi` decoded,
so this is the check that each video decodes, not only that its size can be read.

Both the import and `psi info <file>` read each image's EXIF as well as its size, and a failed EXIF read is an error, not
an image with no date. So every file, including the JPEGs with no EXIF or a broken EXIF segment, must import, and a file
`psi info` could not read is reported with the error it printed, which for an EXIF read names the `identify` command and
the file.

Every `psi` command runs with a `PATH` that is a single empty directory, so each file is read by the ImageMagick and
FFmpeg built into `psi`, never by a `magick`, `ffmpeg` or `ffprobe` installed on the machine.

```
bun run build:cli
bash scripts/make-format-test-images.sh
bash scripts/check-format-test-images.sh [psi executable]
```

- `psi executable`: optional, defaults to `zig-out/bin/psi`. The script does not build it.

Prints `ok` or `FAIL` per image and exits 1 if any image failed to import, was recorded with the wrong size or has no thumbnail of its shape. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
