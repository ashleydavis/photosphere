# make-format-test-images.sh

Makes the images and videos the format tests read (`getImageDetails reads the size of every non-JPEG image type...` in
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
- The same 71x37 JPEG with a broken EXIF segment: an IFD claiming 65535 entries, an IFD offset past the end of the
  segment, and a TIFF header with no byte order. ImageMagick still reads these and their EXIF, so they must import;
  an EXIF read that fails is an error, so a file like these that stopped importing would show in the check.
- Two-second videos with sound: H.264 and HEVC, each in MP4 and MOV.
- The other video types phones and cameras record that the import takes: H.263 and H.264 in 3GP, H.264 in M4V and
  MKV, Motion JPEG with PCM sound and MPEG-4 Part 2 (tagged XVID) in AVI, MPEG-2 in MPG and VOB, MPEG-1 in MPEG,
  VP9 and VP8 in WebM, WMV 8 with WMA sound in ASF (`.wmv`), Microsoft MPEG-4 v3 (DivX 3) in AVI, and PAL DV (720x576, one
  of the two sizes the DV encoder takes) in AVI and MOV. The built-in FFmpeg is built with the demuxer and decoder of each.
- A video named `-not-imported`, which the import must not add: H.264 in MPEG-TS (`.mts`, as AVCHD camcorders
  write), whose content type `video/mp2t` the scanner leaves out because a TypeScript `.ts` file has it too.
- `1000x700-tiled.heic`, a copy of `test/heic/tiled.heic`: a phone's HEIC stored as tiles, which the built-in FFmpeg
  decodes and joins.

A missing file makes the unit test fail on it and makes check-format-test-images.sh fail naming this script; neither skips.
