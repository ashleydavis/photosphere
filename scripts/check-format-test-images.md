# check-format-test-images.sh

Imports every image and video in `test/formats/` into a new database with the built `psi`, then checks the width and height
`psi` recorded for each against the size at the start of its file name (`53x31-alpha.png` must be 53 × 31). A JPEG
with an EXIF Orientation of 6 or 8 stands upright when turned, so it must be recorded with the size swapped.

Both the import and `psi info <file>` read each image's EXIF as well as its size, and a failed EXIF read is an error, not
an image with no date. So every file, including the JPEGs with no EXIF or a broken EXIF segment, must import, and a file
`psi info` could not read is reported with the error it printed, which for an EXIF read names the `identify` command and
the file.

Each file that imported with the right size must also have a JPEG thumbnail in the database, and each image a JPEG
display picture too (`thumb/<asset id>` and `display/<asset id>`, each starting with the JPEG marker `FF D8 FF`). A video's
thumbnail is made from a screenshot of it, so this shows the built-in FFmpeg decoded a frame of every video type, not only
read its size from the container. A video has no display picture.

A file whose name holds `-not-imported` is a type the import must not add: the check fails if `psi list` shows it in the
database.

Every `psi` command runs with a `PATH` that is a single empty directory, so each file is read by the ImageMagick and
FFmpeg built into `psi`, never by a `magick`, `ffmpeg` or `ffprobe` installed on the machine.

```
bun run build:cli
bash scripts/make-format-test-images.sh
bash scripts/check-format-test-images.sh [psi executable]
```

- `psi executable`: optional, defaults to `zig-out/bin/psi`. The script does not build it.

Prints `ok` or `FAIL` per image and exits 1 if any image or video failed to import, was recorded with the wrong size or has no thumbnail, or if a `-not-imported` file was imported. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
