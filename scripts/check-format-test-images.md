# check-format-test-images.sh

Imports every image and video in `test/formats/` into a new database with the built `psi`, then checks the width and height
`psi` recorded for each against the size at the start of its file name (`53x31-alpha.png` must be 53 × 31). A JPEG
with an EXIF Orientation of 6 or 8 stands upright when turned, so it must be recorded with the size swapped.

Both the import and `psi info <file>` read each image's EXIF as well as its size, and a failed EXIF read is an error, not
an image with no date. So every file, including the JPEGs with no EXIF or a broken EXIF segment, must import, and a file
`psi info` could not read is reported with the error it printed, which for an EXIF read names the `identify` command and
the file.

Every `psi` command runs with a `PATH` that is a single empty directory, so each file is read by the ImageMagick and
FFmpeg built into `psi`, never by a `magick`, `ffmpeg` or `ffprobe` installed on the machine.

Then it checks the colour of the display, thumbnail and micro copies `psi` makes of every image (not the videos, whose
size alone is checked). Each image is imported again into a database of its own, so its copies are the only ones there:
the display and thumbnail copies are read from the database's `display` and `thumb` directories, and the micro thumbnail
is the one base64 JPEG in the database's metadata. Each copy must be sRGB (or Gray, for a picture with no colour in it),
carry no colour profile, and have a mean colour within 3 per channel of the image shown through its own profile: for a file with a colour profile, ImageMagick's
conversion of it into sRGB with `third-party/imagemagick/vendor/imagemagick/config/sRGB.icm`, and for a file with none,
its own pixels. So a Display P3 or CMYK file whose copies kept their numbers and lost their profile fails, and so does a
file with no profile whose copies changed colour. This part runs the ImageMagick installed on the machine (`magick`, or
`convert` for ImageMagick 6) for the reference colours; `psi` itself still runs with the empty `PATH`.

```
bun run build:cli
bash scripts/make-format-test-images.sh
bash scripts/check-format-test-images.sh [psi executable]
```

- `psi executable`: optional, defaults to `zig-out/bin/psi`. The script does not build it.

Prints `ok` or `FAIL` per image and per copy, and exits 1 if any image failed to import, was recorded with the wrong size,
or has a copy that is not sRGB, keeps a profile or has the wrong colour. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
