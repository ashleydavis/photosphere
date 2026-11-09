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

Each file that imported with the right size must also have a JPEG thumbnail in the database, and each image a JPEG
display picture too (`thumb/<asset id>` and `display/<asset id>`, each starting with the JPEG marker `FF D8 FF`). A video's
thumbnail is made from a screenshot of it, so this shows the built-in FFmpeg decoded a frame of every video type, not only
read its size from the container. A video has no display picture.

A file whose name holds `-not-imported` is a type the import must not add: the check fails if `psi list` shows it in the
database.

Then it writes an SVG, a PostScript file and a portable pixmap, named `.png` or `.jpg` so the import hands them to
ImageMagick, imports them into a second database and checks that each was refused with ImageMagick's `NotAuthorized`
error naming its coder and that none was added. ImageMagick picks the coder from the file's first bytes, so this is
the security policy in `packages-zig/media-tools-zig/src/lib/image-magick.zig` refusing every type it does not allow.

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

Prints `ok` or `FAIL` per file, per copy and per refused type, and exits 1 if any image or video failed to import, was
recorded with the wrong size, is missing a picture or has a thumbnail of the wrong shape, if a `-not-imported` file was
imported, if a copy is not sRGB, keeps a profile or has the wrong colour, or if a type outside the policy was not refused. The
database is made in a new `mktemp -d` directory, printed at the start and left behind for inspection.
