# Updating the bundled ImageMagick and FFmpeg

1. Take the new source: `scripts/update-imagemagick.sh <version>`, `scripts/update-ffmpeg.sh <version>` (and `scripts/update-libjpeg.sh`, `scripts/update-libpng.sh`, `scripts/update-libwebp.sh` for the delegates). Each moves the old copy to `vendor/<name>.previous`; compare it, then delete it.
2. Make the generated files again for every target: run `generate-config.sh` of `packages-zig/media-tools-zig/imagemagick` and of `packages-zig/media-tools-zig/ffmpeg` with each target named in their `.md` files (Android targets need the NDK libc file `apps/photosphere/scripts/sync-android.sh` writes).
3. Build each library alone for each target: `scripts/build-imagemagick.sh --target <target>` and `scripts/build-ffmpeg.sh --target <target>`.
4. Run `bun run test:everything`, which covers the unit tests of `packages-zig/media-tools-zig` and the Linux and Android smoke tests that import photos and videos.
5. Update `THIRD-PARTY-NOTICES.md` if a licence or a delegate changed.

The vendored source is never edited. If a new version does not build unchanged for a target, stop for that target and say so.

## Phones

On Android the libraries are built into `libphotosphere.so` by the core build, and on iOS into the core static library, so the app projects hold no copy of them and carry no ImageMagick or FFmpegKit dependency. ImageMagick has the JPEG, PNG and WebP delegates on every platform, so a WebP picture is read the same way everywhere (no system decoder is used).

## Old mobile apps (deprecated)

The Capacitor apps are updated with `scripts/update-mobile-media-tools.sh`, which is kept until they are removed.
