# make-format-test-images.sh

Makes the images and videos the format tests read (`getImageDetails reads the size of every non-JPEG image type...` and
`getImageDetails makes the pictures of a large JPEG with its reduced decode...` in
`packages-zig/node-api-zig/src/test/image.test.zig`) into `test/formats/`. That directory is gitignored: the images
are made locally, not committed. A file that is already there is kept, so after the first run this is quick.

```
bash scripts/make-format-test-images.sh
```

It takes no arguments and needs ImageMagick (`magick`, or `convert` for ImageMagick 6) and ffmpeg with libx264 and libx265.

What it makes, each with a width and height that differ so a size read the wrong way round shows:

- GIF, BMP (default and V3), PNG with alpha, WebP lossless and lossy, a JPEG with no EXIF.
- An animated GIF, three frames.
- The same 71x37 JPEG with an EXIF Orientation of 1, 3, 6 and 8. ImageMagick does not write that tag into a JPEG with
  no EXIF, so the script writes a minimal EXIF segment holding only it.
- Large JPEGs, red at the top and blue at the bottom, whose pictures are made with a reduced decode: a 5472x3648
  camera photo, and a 4001x2999 photo (sides not multiples of 8) with no EXIF and with an EXIF Orientation of 1, 3, 6
  and 8. `getImageDetails makes the pictures of a large JPEG with its reduced decode...` in the same test file reads them.
- Two-second videos with sound: H.264 and HEVC, each in MP4 and MOV.

A missing file makes the unit test fail on it and makes check-format-test-images.sh fail naming this script; neither skips.
