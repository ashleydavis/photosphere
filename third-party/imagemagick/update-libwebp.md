# update-libwebp.sh

Takes a given upstream libwebp version's source into `third-party/imagemagick/vendor/libwebp`. It is the WebP delegate ImageMagick is built over. The vendored source is never edited or patched.

```
third-party/imagemagick/update-libwebp.sh <version>
```

- `<version>`: a libwebp release, for example `1.6.0`. The source is downloaded from `https://github.com/webmproject/libwebp/archive/refs/tags/v<version>.tar.gz`.

It leaves out the example programs, the documentation and the test pictures, writes `third-party/imagemagick/vendor/libwebp/VENDORED_VERSION` and moves the copy that was there to `third-party/imagemagick/vendor/libwebp.previous` rather than deleting it; compare them, then delete the old one yourself. After taking a new version, make ImageMagick's generated headers again (`third-party/imagemagick/generate-config.md`) and build and test ImageMagick (`zig build` in `third-party/imagemagick`). The download and unpacking is in `third-party/imagemagick/vendor-library.sh`.
