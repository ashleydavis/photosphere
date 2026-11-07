# update-zlib-ng.sh

Moves the zlib-ng this build fetches to a given upstream release. The source is not kept in the repository: `build.zig.zon` names the release tarball and its hash, and Zig fetches it.

```
third-party/zlib-ng/update-zlib-ng.sh <version>
```

- `<version>`: a release tag of zlib-ng, for example `2.3.3`. The tarball is `https://github.com/zlib-ng/zlib-ng/archive/refs/tags/<version>.tar.gz`.

It runs `zig fetch --save=zlib-ng` in this directory, which downloads the release and writes its url and hash into the `zlib-ng` entry of `build.zig.zon`. After taking a new release, compare the release's `CMakeLists.txt` with what `zlib-ng.zig` mirrors (the sources, the definitions and the CPU-specific parts) and carry over any change, then build it with `zig build` in this directory. FFmpeg's and ImageMagick's builds use this zlib-ng too, so build and test them afterwards.
