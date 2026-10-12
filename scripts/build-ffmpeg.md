# build-ffmpeg.sh

Builds FFmpeg as a static library for one target: libavutil, libavcodec, libavformat, libavfilter, libswscale and libswresample, with the `ffmpeg` and `ffprobe` command line programs compiled in as functions the app can call (their `main` functions are renamed by the compiler flags the build passes). It is how to build and check FFmpeg by itself; the app builds the same library as part of its core (see `packages-zig/media-tools-zig`).

```
scripts/build-ffmpeg.sh [--target <zig-target>] [--libc-file <file>] [--output-dir <dir>]
```

- `--target`: the target to build for, as Zig names it. Without it the library is built for this machine. The targets that have generated files (see `packages-zig/media-tools-zig/ffmpeg/generate-config.md`) are `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-android`, `aarch64-linux-android`, `x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`. The iOS targets (`aarch64-ios`, `aarch64-ios-simulator`, `x86_64-ios-simulator`) build on a Mac with Xcode and stop elsewhere with a message naming the iOS SDK.
- `--libc-file`: Zig's libc file for the Android NDK, which the Android targets need because Zig has no C library for Android. `apps/photosphere/scripts/sync-android.sh` writes one for each ABI.
- `--output-dir`: where the library is installed. Without it, `zig-out/ffmpeg/<target>`.

The library is built from the unmodified source in `vendor/ffmpeg` and the zlib-ng the rest of the core uses. The script that takes the source is `scripts/update-ffmpeg.sh`.
