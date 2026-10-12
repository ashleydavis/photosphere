# build-imagemagick.sh

Builds ImageMagick, with its libjpeg, libpng, libwebp and zlib, as a static library for one target. It is how to build and check ImageMagick by itself; the app builds the same library as part of its core (see `packages-zig/media-tools-zig`).

```
scripts/build-imagemagick.sh [--target <zig-target>] [--libc-file <file>] [--output-dir <dir>]
```

- `--target`: the target to build for, as Zig names it. Without it the library is built for this machine. The targets that have generated headers (see `packages-zig/media-tools-zig/imagemagick/generate-config.md`) are `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-android`, `aarch64-linux-android`, `x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`. The iOS targets (`aarch64-ios`, `aarch64-ios-simulator`, `x86_64-ios-simulator`) are named by the build, which stops with the reason it cannot build them yet.
- `--libc-file`: Zig's libc file for the Android NDK, which the Android targets need because Zig has no C library for Android. `apps/photosphere/scripts/sync-android.sh` writes one for each ABI.
- `--output-dir`: where the library is installed. Without it, `zig-out/imagemagick/<target>`.

The library is built from the unmodified source in `vendor/imagemagick`, `vendor/libjpeg`, `vendor/libpng` and `vendor/libwebp`, and the zlib-ng the rest of the core uses. The scripts that take those sources are `scripts/update-imagemagick.sh`, `scripts/update-libjpeg.sh`, `scripts/update-libpng.sh` and `scripts/update-libwebp.sh`.
