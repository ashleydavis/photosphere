# update-libjpeg.sh

Takes a given Independent JPEG Group libjpeg release into `vendor/libjpeg`. It is the JPEG delegate ImageMagick is built over. The vendored source is never edited or patched.

```
scripts/update-libjpeg.sh <release>
```

- `<release>`: a release of the IJG library, for example `9f`. The source is downloaded from `https://www.ijg.org/files/jpegsrc.v<release>.tar.gz`.

It writes `vendor/libjpeg/VENDORED_VERSION` and moves the copy that was there to `vendor/libjpeg.previous` rather than deleting it; compare them, then delete the old one yourself. After taking a new release, build and test ImageMagick (`scripts/build-imagemagick.md`). If the new release adds a symbol to `jconfig.cfg`, the build stops and names it; give it a value in `packages-zig/media-tools-zig/libjpeg/libjpeg.zig`. The shared work is in `scripts/lib/vendor-library.sh`.
