# update-lcms2.sh

Takes a given upstream Little CMS 2 (lcms2) version's source into `third-party/imagemagick/vendor/lcms2`. It is the colour management delegate ImageMagick is built over: with it, `-profile` converts the pixels of a picture from the colour profile embedded in it to another one, which is how a resized copy is turned into sRGB before its metadata is stripped. The vendored source is never edited or patched.

```
third-party/imagemagick/update-lcms2.sh <version>
```

- `<version>`: an lcms2 release, for example `2.20`. The source is the release tarball the project publishes, downloaded from `https://github.com/mm2/Little-CMS/releases/download/lcms<version>/lcms2-<version>.tar.gz`.

It leaves out the documentation, the test profiles and programs, the command line utilities, the plugins, the fuzzers and the projects of other build systems, writes `third-party/imagemagick/vendor/lcms2/VENDORED_VERSION` and moves the copy that was there to `third-party/imagemagick/vendor/lcms2.previous` rather than deleting it; compare them, then delete the old one yourself. After taking a new version, make ImageMagick's generated headers again (`third-party/imagemagick/generate-config.md`) and build and test ImageMagick (`zig build` in `third-party/imagemagick`). The download and unpacking is in `third-party/imagemagick/vendor-library.sh`.
