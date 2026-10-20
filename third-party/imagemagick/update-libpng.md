# update-libpng.sh

Takes a given upstream libpng version's source into `third-party/imagemagick/vendor/libpng`. It is the PNG delegate ImageMagick is built over. The vendored source is never edited or patched.

```
third-party/imagemagick/update-libpng.sh <version>
```

- `<version>`: a libpng release, for example `1.6.59`. The source is downloaded from `https://github.com/pnggroup/libpng/archive/refs/tags/v<version>.tar.gz`.

It leaves out the test pictures, the contributed programs and the projects, writes `third-party/imagemagick/vendor/libpng/VENDORED_VERSION` and moves the copy that was there to `third-party/imagemagick/vendor/libpng.previous` rather than deleting it; compare them, then delete the old one yourself. After taking a new version, build and test ImageMagick (`zig build` in `third-party/imagemagick`). The download and unpacking is in `third-party/imagemagick/vendor-library.sh`.
