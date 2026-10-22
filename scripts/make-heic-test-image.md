# make-heic-test-image.ts

Makes a HEIC picture for the tests, laid out the way an iPhone writes one: a grid of 512 by 512 HEVC tiles trimmed to the picture's size, with an EXIF item carrying a date, a GPS position and an Orientation. `test/heic/tiled.heic` was made with it.

```
bun scripts/make-heic-test-image.ts --output <file.heic> --width <pixels> --height <pixels> --date <YYYY:MM:DD HH:MM:SS> --latitude <degrees> --longitude <degrees> [--orientation <1-8>]
```

- `--output`: the HEIC file to write.
- `--width`, `--height`: the picture's size in pixels, up to 65535 each. A size that is not a multiple of 512 gives a grid that is trimmed, as a phone's is.
- `--date`: the EXIF DateTimeOriginal and CreateDate, written as EXIF writes dates.
- `--latitude`, `--longitude`: the EXIF GPS position, in degrees, north and east positive.
- `--orientation`: the EXIF Orientation, 1 (upright) when it is not given.

It needs `ffmpeg` built with libx265 and `exiftool` on the PATH. Nothing common writes HEIC, so FFmpeg encodes each tile into an MP4 and exiftool writes the EXIF into a small JPEG, and the script takes the tiles, their decoder configuration and the EXIF out of those and writes them into a HEIF file's boxes. The picture is FFmpeg's `testsrc2` pattern, so the file carries nobody's copyright. Its working files go in a new directory under the repository's `tmp/`.
