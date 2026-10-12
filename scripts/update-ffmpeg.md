# update-ffmpeg.sh

Takes a given upstream FFmpeg version's source into `vendor/ffmpeg`. Run it when you want a newer FFmpeg; nothing else changes the vendored source, which is never edited or patched.

```
scripts/update-ffmpeg.sh <version>
```

- `<version>`: an FFmpeg release, for example `9.0.2`. The source is downloaded from `https://ffmpeg.org/releases/ffmpeg-<version>.tar.xz`.

What it does:

- Unpacks the release into `vendor/ffmpeg`, leaving out the reference output of FFmpeg's own tests, the presets and the player. The rest of the tests directory stays because FFmpeg's top level Makefile includes it, and the file lists of the Zig build are read from that Makefile.
- Writes `vendor/ffmpeg/VENDORED_VERSION` with the version and the address it came from.
- Moves the copy that was there to `vendor/ffmpeg.previous` rather than deleting it. Compare the two, then delete the old one yourself.

After taking a new version, make the generated headers and file lists again for every target (`packages-zig/media-tools-zig/ffmpeg/generate-config.md`) and build and test the library (`scripts/build-ffmpeg.md`). The shared work is in `scripts/lib/vendor-library.sh`.
