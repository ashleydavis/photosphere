# generate-config.sh

Makes the headers ImageMagick's own `configure` script writes for a target, so the Zig build can compile ImageMagick without running `configure` on every machine that builds. Run it for each target when ImageMagick is taken at a new version (`scripts/update-imagemagick.md`); the results are kept in `config/<target>/MagickCore/`.

```
packages-zig/media-tools-zig/imagemagick/generate-config.sh <zig-target> [<libc-file>]
```

- `<zig-target>`: the target as Zig names it: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-android`, `aarch64-linux-android`, `x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-windows-msvc`, `x86_64-macos`, `aarch64-macos`, `aarch64-ios`, `aarch64-ios-simulator` or `x86_64-ios-simulator`. The iOS targets need Apple's iOS SDK (found with `xcrun` and given to the compiler as its sysroot), so they can only be generated on a Mac with Xcode. `x86_64-windows-msvc` (what the Photosphere App's Windows shell is built for) needs the Windows SDK's headers, so it can only be generated on Windows with Visual Studio or its Build Tools.
- `<libc-file>`: Zig's libc file for the Android NDK, which the Android targets need. `apps/photosphere/scripts/sync-android.sh` writes one for each ABI.

It needs `pkg-config` on the PATH, because `configure` finds libpng, libwebp and zlib only through it. Git Bash has none, so on Windows install one first (MSYS2's `pkgconf`, for one). The script stops with an error when there is none, and when the header it made has any of the JPEG, PNG, WebP or zlib delegates off, since `configure` turns a delegate it cannot find off without an error.

How it works:

- It runs `vendor/imagemagick/configure` out of tree under `tmp/imagemagick-config/<target>/`, with `zig cc -target <target>` as the compiler, so the answers are the ones for that target's C library headers and not for the machine running the script.
- The options turn on JPEG, PNG, WebP (single pictures: libwebpmux is off) and zlib and turn every other delegate off, with quantum depth 16, HDRI, threads and zero configuration (the program carries its configuration inside it and reads none from the machine it runs on). The libraries are built by the Zig build and do not exist yet when `configure` runs, so their checks are answered with the variables `configure` documents for that: pkg-config is pointed at a directory of its own that holds a description of zlib, libpng and libwebp (with the versions of the vendored source), so a library installed on the machine cannot be found instead, `JPEG_CFLAGS` and `JPEG_LIBS` stand in for the JPEG package, and `ac_cv_lib_jpeg_jpeg_read_header=yes` answers the one link check. The headers the JPEG check reads are copied from `vendor/libjpeg` with a `jconfig.h`.
- `configure` is stopped before it writes the Makefiles and the man pages and the pkg-config files, whose templates are not vendored, and `config.status` is run for the three files the build needs: `MagickCore/magick-baseconfig.h`, `MagickCore/version.h` and `config/config.h`. The first two are copied to `config/<target>/MagickCore/`.

The vendored source is not changed.
