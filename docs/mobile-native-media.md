# Bundled ImageMagick and FFmpeg

The Photosphere App (on the desktop and on phones) and the Zig CLI (`psi`) call ImageMagick and FFmpeg inside their own process on every platform, through the same `MediaTools`. Nothing is installed on the machine and neither starts a program for them. The Zig core links both libraries statically (`packages-zig/media-tools-zig`) and runs the same argument lists the TypeScript and Zig code have always built for `magick`, `ffmpeg` and `ffprobe`.

## How it fits together

- `MediaTools` (`packages-zig/media-tools-zig/src/lib/media-tools.zig`) owns ImageMagick and FFmpeg and gives out an `InProcessRunner`. The App's core makes one at startup and hands it to the task queue, so every task context carries it as `toolRunner`. The CLI's `main` makes one for the whole run and passes it down to each command and to its worker pool, which puts its runner into the context of every task it runs. Photosphere's code that runs `magick`, `ffmpeg` or `ffprobe` takes the runner as a required argument, so it has no path that starts an installed program. A task handler that reads the runner from its context (`check`, `hash-file` and `upload-asset`) fails when the context has none, with an error saying ImageMagick and FFmpeg are built into the program and the task was run with no runner for them.
- ImageMagick runs through its own command dispatcher. What a command prints is collected without touching standard output: `identify` hands its text back, `-version` writes to a file, and a command ending in `info:` is pointed at a temporary file. It is thread safe.
- FFmpeg runs through the `main` functions of `ffmpeg` and `ffprobe` (renamed by compiler flags). They keep state for the whole program, so one command runs at a time, and the counts they leave behind are reset after each run. `ffprobe` writes its report to a temporary file. What FFmpeg logs goes to the program's log (see below).
- Delegates and zlib: libjpeg, libpng and libwebp (single pictures; the animated-picture parts are not built) are built beside ImageMagick, over the same zlib-ng the rest of the core uses. WebP is read and written the same way on every platform, so a WebP picture imports on a phone as it does on a desktop.

## Image types the built-in ImageMagick cannot read

ImageMagick is configured with only the JPEG, PNG, WebP and zlib delegates (`third-party/imagemagick/generate-config.sh`); every other delegate is turned off. It reads what its own coders read, such as GIF, BMP, ICO, TGA and PSD, but it cannot read HEIC, HEIF, AVIF, TIFF, JPEG 2000, JPEG XL, OpenEXR, DjVu, FlashPix, WMF, XWD or DNG, each of which needs a delegate it does not have. HEIC and HEIF are handled without ImageMagick: FFmpeg (built with its `xstack` filter, which joins a phone's tiled HEIC) gives their size and decodes them into a JPEG that ImageMagick makes the smaller pictures from, and their EXIF is read from the file by `packages-zig/node-api-zig/src/lib/heic-exif.zig`. Importing a file of any of the other types fails with ImageMagick's error in the Zig CLI and in the App. An installed ImageMagick could read them through its own delegates, but neither program uses an installed ImageMagick.

## Security policy

The built-in ImageMagick is built with zero configuration, so it reads no `policy.xml`. Instead `ImageMagick.init` (`packages-zig/media-tools-zig/src/lib/image-magick.zig`) sets a policy with `SetMagickSecurityPolicy` straight after `MagickWandGenesis`. It denies:

- The coders that reach outside the file being read or run a script: `URL`, `HTTP`, `HTTPS`, `FTP`, `MSL`, `MVG`, `MSVG`, `TEXT`, `TXT`, `EPHEMERAL`, `SHOW`, `WIN` and `X`. Every other coder stays allowed, because the import reads whatever image type the user has. An allow-list would refuse types it accepts.
- Every delegate, since none is meant to run.
- Indirect reads, the paths starting with `@` that name a file holding a list of files to read.

If the policy cannot be set, `init` stops ImageMagick and returns an error carrying ImageMagick's reason, so `MediaTools.init` fails and the program does not run without it.

## A timed-out ffmpeg

Each run of `ffmpeg` and `ffprobe` has state of its own (`third-party/ffmpeg/fftools-per-run-state.patch`, see `third-party/ffmpeg/update-ffmpeg.md`), so a run that never ends holds only the thread it runs on, and the other workers' runs go on. `ffmpeg_main` reads no task's cancel flag, so cancelling the task does not end the run.

The CLI's worker pool abandons a worker whose task timed out, because a thread cannot be stopped, and the run goes on until it ends on its own; what the worker sends after that is dropped. The App runs tasks on Ziggy's queue, which has no task timeout and abandons no thread.

## Source, builds and scripts

Vendored source (never edited, except FFmpeg's command line programs, patched by `third-party/ffmpeg/fftools-per-run-state.patch`) is in `third-party/imagemagick/vendor/imagemagick`, `third-party/imagemagick/vendor/libjpeg`, `third-party/imagemagick/vendor/libpng`, `third-party/imagemagick/vendor/libwebp` and `third-party/ffmpeg/vendor/ffmpeg`, each with a `VENDORED_VERSION`. The files each target needs that the libraries' own `configure` writes are kept in `third-party/imagemagick/config` and `third-party/ffmpeg/config`.

- Take a version: `third-party/imagemagick/update-imagemagick.sh`, `third-party/imagemagick/update-libjpeg.sh`, `third-party/imagemagick/update-libpng.sh`, `third-party/imagemagick/update-libwebp.sh`, `third-party/ffmpeg/update-ffmpeg.sh` (see their `.md` files).
- Make the generated files for a target: `third-party/imagemagick/generate-config.sh` and `third-party/ffmpeg/generate-config.sh`.
- Build one library alone for a target: `zig build -Dtarget=<target>` in `third-party/imagemagick` and in `third-party/ffmpeg`.

Targets with generated files and a build that has been run here: Linux (x86_64, aarch64), Android (x86_64, aarch64), Windows (x86_64, aarch64) and MacOS (x86_64, aarch64); only Linux x86_64 and Android (on the emulator) have also been run. The iOS targets (device, and simulator on arm64 and x86_64) are defined the same way but can only be built and generated on a Mac with Xcode: elsewhere the build stops with a message naming the iOS SDK. Nothing for iOS has been built or run yet. The core library, including the AWS SDK for C and aws-lc, is defined for the iOS targets (device and both simulators, with the iOS SDK from `xcrun`) and for Windows aarch64, which builds from Linux.

## Messages from the libraries

Neither library prints to the process's standard error. What they say goes back the way the standard error of an installed program did: into the error of a command that failed, and to the log as the tool's standard error (`log.tool`) for a command that worked.

- ImageMagick leaves a command's messages in the exception the command is given. A command that fails hands them back as its output, so the "Command failed" error carries them, and the warnings of a command that worked go to `log.tool`. The process-wide warning and error handlers, which a few parts of ImageMagick still call, are set when `MediaTools` starts to send to `log.tool` and the log's errors, and put back when it stops.
- FFmpeg reports everything through one log callback for the whole process (`av_log_set_callback`), which is given no pointer to the run it belongs to, so the text cannot be tied to a run without a variable for the whole process, which the repository does not allow. The callback sends FFmpeg's errors to the log's errors and everything else at the run's `-loglevel` to `log.tool`. `ffprobe` is also run with `-show_error`, so a failed probe hands back its error in its report, and that is its output. A failed `ffmpeg` hands back no text: its errors are in the log.

## iOS

The ImageMagick and FFmpeg files for the iOS targets are not checked in: they come from the SDK of the Mac doing the build. Make them with the two `generate-config.sh` scripts (`aarch64-ios` for a device, `aarch64-ios-simulator` for the simulator on an arm64 Mac), then build each library in its `third-party` directory for the target (`zig build -Dtarget=aarch64-ios.14.0`). The iOS scripts (`apps/photosphere/scripts/sync-ios.sh`, and so `build-ios.sh`, `package-ios.sh` and `open-ios.sh`) link what those builds installed. The iOS release workflow does both through the library build actions.

## The old mobile apps (deprecated)

The Capacitor apps (`apps/android-frontend`, `apps/ios-frontend`) still use prebuilt ImageMagick libraries and the FFmpegKit forks described in `scripts/fetch-mobile-media-tools.sh` and `apps/ios-frontend/ios/build-imagemagick.sh`. They are removed later and are not changed by the work above.

## Licensing

See `THIRD-PARTY-NOTICES.md` and the README.
