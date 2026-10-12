# update-libpng.sh

Takes a given upstream libpng version's source into `vendor/libpng`. It is the PNG delegate ImageMagick is built over. The vendored source is never edited or patched.

```
scripts/update-libpng.sh <version>
```

- `<version>`: a libpng release, for example `1.6.59`. The source is downloaded from `https://github.com/pnggroup/libpng/archive/refs/tags/v<version>.tar.gz`.

It leaves out the test pictures, the contributed programs and the projects, writes `vendor/libpng/VENDORED_VERSION` and moves the copy that was there to `vendor/libpng.previous` rather than deleting it; compare them, then delete the old one yourself. After taking a new version, build and test ImageMagick (`scripts/build-imagemagick.md`). The shared work is in `scripts/lib/vendor-library.sh`.
