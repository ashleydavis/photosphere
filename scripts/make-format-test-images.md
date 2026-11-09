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

- GIF, BMP (default, which is V5, V3, and V4), PNG with alpha, WebP lossless and lossy, a JPEG with no EXIF. ImageMagick 6
  writes no V4 header, so the script grows a V3 BMP's 40-byte header into the 108-byte V4 one.
- A HEIC laid out as an iPhone writes one, copied from `test/heic/tiled.heic` as `1000x700-tiled.heic`.
- An animated GIF, three frames.
- The same 71x37 JPEG with an EXIF Orientation of 1, 3, 6 and 8. ImageMagick does not write that tag into a JPEG with
  no EXIF, so the script writes a minimal EXIF segment holding only it.
- The same 71x37 JPEG with a broken EXIF segment: an IFD claiming 65535 entries, an IFD offset past the end of the
  segment, and a TIFF header with no byte order. ImageMagick still reads these and their EXIF, so they must import;
  an EXIF read that fails is an error, so a file like these that stopped importing would show in the check.
- Large JPEGs, red at the top and blue at the bottom, whose pictures are made with a reduced decode: a 5472x3648
  camera photo, and a 4001x2999 photo (sides not multiples of 8) with no EXIF and with an EXIF Orientation of 1, 3, 6
  and 8. `getImageDetails makes the pictures of a large JPEG with its reduced decode...` in the same test file reads them.
- Pictures with a colour profile that is not sRGB, each one solid colour: a PNG and a JPEG with a Display P3 profile
  (Display P3 primaries and white point with a 2.2 gamma curve, written byte by byte by the script because neither
  ImageMagick nor this repository ships a wide gamut RGB profile), and a CMYK JPEG carrying the CMYK profile ImageMagick
  ships (`third-party/imagemagick/vendor/imagemagick/config/cmyk.icm`). psi must convert these into sRGB in its copies.
- Two-second videos with sound: H.264 and HEVC, each in MP4 and MOV.

A missing file makes the unit test fail on it and makes check-format-test-images.sh fail naming this script; neither skips.
