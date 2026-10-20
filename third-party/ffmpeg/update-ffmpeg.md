# update-ffmpeg.sh

Takes a given upstream FFmpeg version's source into `third-party/ffmpeg/vendor/ffmpeg`. Run it when you want a newer FFmpeg; nothing else changes the vendored source, which is never edited or patched.

```
third-party/ffmpeg/update-ffmpeg.sh <version>
```

- `<version>`: an FFmpeg release, for example `9.0.2`. The source is downloaded from `https://ffmpeg.org/releases/ffmpeg-<version>.tar.xz`.

What it does:

- Unpacks the release into `third-party/ffmpeg/vendor/ffmpeg`, leaving out the reference output of FFmpeg's own tests, the presets and the player. The rest of the tests directory stays because FFmpeg's top level Makefile includes it, and the file lists of the Zig build are read from that Makefile.
- Writes `third-party/ffmpeg/vendor/ffmpeg/VENDORED_VERSION` with the version and the address it came from.
- Moves the copy that was there to `third-party/ffmpeg/vendor/ffmpeg.previous` rather than deleting it. Compare the two, then delete the old one yourself.

After taking a new version, make the generated headers and file lists again for every target (`third-party/ffmpeg/generate-config.md`) and build and test the library (`zig build` in `third-party/ffmpeg`). The download and unpacking is in `third-party/ffmpeg/vendor-library.sh`.
