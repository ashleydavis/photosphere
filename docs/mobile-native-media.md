# Bundled ImageMagick and FFmpeg

The Photosphere App calls ImageMagick and FFmpeg inside its own process on every platform. Nothing is installed on the machine and the app starts no program. The Zig core links both libraries statically (`packages-zig/media-tools-zig`) and runs the same argument lists the TypeScript and Zig code have always built for `magick`, `ffmpeg` and `ffprobe`.

## How it fits together

- `MediaTools` (`packages-zig/media-tools-zig/src/lib/media-tools.zig`) owns ImageMagick and FFmpeg and gives out an `InProcessRunner`. The core makes one at startup and hands it to the task queue, so every task context carries it as `toolRunner`. Code that runs a tool with a runner runs it in process; with none (the CLI) it starts the installed program.
- ImageMagick runs through its own command dispatcher. What a command prints is collected without touching standard output: `identify` hands its text back, `-version` writes to a file, and a command ending in `info:` is pointed at a temporary file. It is thread safe.
- FFmpeg runs through the `main` functions of `ffmpeg` and `ffprobe` (renamed by compiler flags). They keep state for the whole program, so one command runs at a time, and the counts they leave behind are reset after each run. `ffprobe` writes its report to a temporary file. What FFmpeg logs goes to standard error.
- Delegates and zlib: libjpeg, libpng and libwebp (single pictures; the animated-picture parts are not built) are built beside ImageMagick, over the same zlib-ng the rest of the core uses. WebP is read and written the same way on every platform, so a WebP picture imports on a phone as it does on a desktop.

## Source, builds and scripts

Vendored source (never edited) is in `vendor/imagemagick`, `vendor/libjpeg`, `vendor/libpng`, `vendor/libwebp` and `vendor/ffmpeg`, each with a `VENDORED_VERSION`. The files each target needs that the libraries' own `configure` writes are kept in `packages-zig/media-tools-zig/imagemagick/config` and `packages-zig/media-tools-zig/ffmpeg/config`.

- Take a version: `scripts/update-imagemagick.sh`, `scripts/update-libjpeg.sh`, `scripts/update-libpng.sh`, `scripts/update-libwebp.sh`, `scripts/update-ffmpeg.sh` (see their `.md` files).
- Make the generated files for a target: `packages-zig/media-tools-zig/imagemagick/generate-config.sh` and `packages-zig/media-tools-zig/ffmpeg/generate-config.sh`.
- Build one library alone for a target: `scripts/build-imagemagick.sh` and `scripts/build-ffmpeg.sh`.

Targets with generated files and a build that has been run here: Linux (x86_64, aarch64), Android (x86_64, aarch64), Windows (x86_64, aarch64) and MacOS (x86_64, aarch64); only Linux x86_64 and Android (on the emulator) have also been run. The iOS targets (device, and simulator on arm64 and x86_64) are defined the same way but can only be built and generated on a Mac with Xcode: elsewhere the build stops with a message naming the iOS SDK. Nothing for iOS has been built or run yet. The core library, including the AWS SDK for C and aws-lc, is defined for the iOS targets (device and both simulators, with the iOS SDK from `xcrun`) and for Windows aarch64, which builds from Linux.

## Messages from the libraries

What ImageMagick and FFmpeg say about a failure goes to standard error and not into the result of the command. Both libraries report it through one callback for the whole process (`SetErrorHandler` and `SetWarningHandler` for ImageMagick, `av_log_set_callback` for FFmpeg) that carries no pointer to the call it belongs to, and ImageMagick clears the exception it keeps for a call before the command returns. Giving the text to the right call would take a variable for the whole process, which the repository does not allow without being asked.

## iOS

The iOS scripts (`apps/photosphere/scripts/sync-ios.sh`, and so `build-ios.sh`, `package-ios.sh` and `open-ios.sh`) make the ImageMagick and FFmpeg files for the target when they are missing, by the two `generate-config.sh` scripts and the SDK from `xcrun`, then build the libraries into the core static library. This is written and has not been run: it needs a Mac. The core library itself still does not build for iOS, because `aws-lc.zig` and `aws-sdk.zig` stop the build for any target that is not Linux, Windows or macOS.

## The old mobile apps (deprecated)

The Capacitor apps (`apps/android-frontend`, `apps/ios-frontend`) still use prebuilt ImageMagick libraries and the FFmpegKit forks described in `scripts/fetch-mobile-media-tools.sh` and `apps/ios-frontend/ios/build-imagemagick.sh`. They are removed later and are not changed by the work above.

## Licensing

See `THIRD-PARTY-NOTICES.md` and the README.
