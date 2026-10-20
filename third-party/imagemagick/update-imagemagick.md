# update-imagemagick.sh

Takes a given upstream ImageMagick version's source into `third-party/imagemagick/vendor/imagemagick`. Run it when you want a newer ImageMagick; nothing else changes the vendored source, which is never edited or patched.

```
third-party/imagemagick/update-imagemagick.sh <version>
```

- `<version>`: an ImageMagick release tag, for example `7.1.2-33`. The source is downloaded from `https://github.com/ImageMagick/ImageMagick/archive/refs/tags/<version>.tar.gz`.

What it does:

- Unpacks the release into `third-party/imagemagick/vendor/imagemagick`, leaving out what the build does not use (the other language bindings, the web site, tests, fuzzing and packaging files, examples, logos and the repository's own metadata).
- Writes `third-party/imagemagick/vendor/imagemagick/VENDORED_VERSION` with the version and the address it came from.
- Writes `third-party/imagemagick/config/common/MagickCore/threshold-map.h` from the new `config/thresholds.xml`, with the same command ImageMagick's `MagickCore/Makefile.am` uses. `MagickCore/threshold.c` includes it.
- Moves the copy that was there to `third-party/imagemagick/vendor/imagemagick.previous` rather than deleting it. Compare the two, then delete the old one yourself.

After taking a new version, make the generated headers again for every target (`third-party/imagemagick/generate-config.md`) and build and test each library (`zig build` in `third-party/imagemagick`). The download and unpacking is in `third-party/imagemagick/vendor-library.sh`.
