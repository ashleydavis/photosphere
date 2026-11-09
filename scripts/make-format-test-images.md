# make-format-test-images.sh

Makes the images the format tests read (`getImageDetails reads the size of every non-JPEG image type...` in
`packages-zig/node-api-zig/src/test/image.test.zig`) into `test/formats/`. That directory is gitignored: the images
are made locally, not committed. An image that is already there is kept, so after the first run this is quick.

```
bash scripts/make-format-test-images.sh
```

It takes no arguments and needs ImageMagick (`magick`, or `convert` for ImageMagick 6).

What it makes, each with a width and height that differ so a size read the wrong way round shows:

- GIF, BMP (default and V3), PNG with alpha, WebP lossless and lossy, a JPEG with no EXIF.
- An animated GIF, three frames.
- The same 71x37 JPEG with an EXIF Orientation of 1, 3, 6 and 8. ImageMagick does not write that tag into a JPEG with
  no EXIF, so the script writes a minimal EXIF segment holding only it.

A test whose image is missing fails and names this script; it does not skip.
