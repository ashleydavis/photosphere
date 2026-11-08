# Bundled ImageMagick and FFmpeg

The Photosphere App (on the desktop and on phones) and the Zig CLI (`psi`) call ImageMagick and FFmpeg inside their own process on every platform, through the same library functions. Nothing is installed on the machine and neither starts a program for them. The Zig core links both libraries statically and calls their C interfaces from `packages-zig/media-tools-zig`: ImageMagick's MagickCore, and FFmpeg's libavformat, libavcodec, libavutil and libswscale. No command line is built or parsed for `magick`, `ffmpeg` or `ffprobe`.

## How it fits together

- `packages-zig/media-tools-zig` has one function for each thing Photosphere does to a picture or a video, each taking typed arguments:
  - ImageMagick (`src/lib/image-magick.zig`): `readImageInfo` (width, height and format, without decoding the pixels), `readExif` (the EXIF tags), `resizeImage` (to a width, a height or both, fitted or exact, with every profile removed, in a format and at a quality), `transformImage` (mirrored and turned, as an EXIF orientation says), `dominantColor` (the image resized to one pixel), `writeRgbImage` (pixels FFmpeg decoded, turned and written as a JPEG), and `version`, `quantum`, `delegates` and `check`.
  - FFmpeg (`src/lib/ffmpeg.zig`): `probeFile` (duration, bitrate, container tags and each stream's kind, codec, size, pixel format and frame rate), `extractFrame` (the first frame at or after a time, sought to the key frame before it, turned upright as the video's display matrix says), `readPictureSize` and `decodePicture` (a HEIC or HEIF: its tile grid decoded, put in place over the grid's background and trimmed, as the `ffmpeg` program does), and `version`.
- Every function works the first time it is called, on whatever thread calls it, with nothing set up before it and nothing stopped after it. Photosphere's code that works on pictures and videos (`packages-zig/tools-zig`) calls them directly from any task.
  - ImageMagick's state for the whole process is started by `MagickCoreGenesis`, which every function calls first. It is ImageMagick's own once-only step: it takes a mutex ImageMagick initialises statically (`MagickCore/mutex.h`) and returns at once when the state is already started. Nothing stops it; the process's end frees what it holds.
  - FFmpeg needs no start since version 4.0.
  - The program keeps no variable and takes no lock of its own for either library.
- Paths are handed to the libraries as they are, so a path holding a space, `$`, a backtick or `"` reaches them unchanged. ImageMagick reads a path as a file name (so a `png:` prefix names a format, as it did on the command line); the files it writes are encoded in memory and written by the program, so the output path is never read by ImageMagick at all.
- A call that fails throws an error naming the operation and the file, with the libraries' own messages. Each operation is logged at verbose.
- Delegates and zlib: libjpeg, libpng and libwebp (single pictures; the animated-picture parts are not built) are built beside ImageMagick, over the same zlib-ng the rest of the core uses. WebP is read and written the same way on every platform, so a WebP picture imports on a phone as it does on a desktop.

## Image types the built-in ImageMagick cannot read

ImageMagick is configured with only the JPEG, PNG, WebP and zlib delegates (`third-party/imagemagick/generate-config.sh`); every other delegate is turned off. It reads what its own coders read, such as GIF, BMP, ICO, TGA and PSD, but it cannot read HEIC, HEIF, AVIF, TIFF, JPEG 2000, JPEG XL, OpenEXR, DjVu, FlashPix, WMF, XWD or DNG, each of which needs a delegate it does not have. HEIC and HEIF are handled without ImageMagick: FFmpeg gives their size and decodes them (a phone's HEIC is a grid of tiles, which `decodePicture` puts in place) into a JPEG that ImageMagick makes the smaller pictures from, and their EXIF is read from the file by `packages-zig/node-api-zig/src/lib/heic-exif.zig`. Importing a file of any of the other types fails with ImageMagick's error in the Zig CLI and in the App. An installed ImageMagick could read them through its own delegates, but neither program uses an installed ImageMagick.

## Security policy

The built-in ImageMagick is built with zero configuration, so it reads no `policy.xml`. Instead the first call of any function of `packages-zig/media-tools-zig/src/lib/image-magick.zig` sets a policy with `SetMagickSecurityPolicy`, straight after `MagickCoreGenesis` (`applySecurityPolicy`). The policy is read back from ImageMagick rather than remembered by the program: it is in place when `MVG`, which it denies and which ImageMagick allows with no policy, may not be read. ImageMagick loads a policy into its list in one step under its own policy semaphore, and reads the list under the same semaphore, so a thread sees none of the policy or all of it; two threads that both find it missing both apply it, and the list then holds its rules twice, which denies exactly what it denied once. It denies:

- The coders that reach outside the file being read or run a script: `URL`, `HTTP`, `HTTPS`, `FTP`, `MSL`, `MVG`, `MSVG`, `TEXT`, `TXT`, `EPHEMERAL`, `SHOW`, `WIN` and `X`. Every other coder stays allowed, because the import reads whatever image type the user has. An allow-list would refuse types it accepts.
- Every delegate, since none is meant to run.
- Indirect reads, the paths starting with `@` that name a file holding a list of files to read.

If the policy cannot be set, the call fails with an error carrying ImageMagick's reason, and so does every later call until it can be set: no ImageMagick work runs without it.

## A frame that takes long

`extractFrame` and `decodePicture` run on the thread that calls them (FFmpeg's decoder may start threads of its own for the call, which end with it), so a call that never ends holds only that thread, and the other workers' calls go on. They read no task's cancel flag, so cancelling the task does not end the call.

The CLI's worker pool abandons a worker whose task timed out, because a thread cannot be stopped, and the call goes on until it ends on its own; what the worker sends after that is dropped. The App runs tasks on Ziggy's queue, which has no task timeout and abandons no thread.

## Source, builds and scripts

Vendored source (never edited, except FFmpeg's command line programs, patched by `third-party/ffmpeg/fftools-per-run-state.patch`, which FFmpeg's build still compiles into its library although nothing calls them) is in `third-party/imagemagick/vendor/imagemagick`, `third-party/imagemagick/vendor/libjpeg`, `third-party/imagemagick/vendor/libpng`, `third-party/imagemagick/vendor/libwebp` and `third-party/ffmpeg/vendor/ffmpeg`, each with a `VENDORED_VERSION`. The files each target needs that the libraries' own `configure` writes are kept in `third-party/imagemagick/config` and `third-party/ffmpeg/config`. FFmpeg's build installs no headers, so the root `build.zig` translates the headers `media-tools-zig` uses from the vendored source, with the target's `libavutil/avconfig.h` from `third-party/ffmpeg/config`.

- Take a version: `third-party/imagemagick/update-imagemagick.sh`, `third-party/imagemagick/update-libjpeg.sh`, `third-party/imagemagick/update-libpng.sh`, `third-party/imagemagick/update-libwebp.sh`, `third-party/ffmpeg/update-ffmpeg.sh` (see their `.md` files).
- Make the generated files for a target: `third-party/imagemagick/generate-config.sh` and `third-party/ffmpeg/generate-config.sh`.
- Build one library alone for a target: `zig build -Dtarget=<target>` in `third-party/imagemagick` and in `third-party/ffmpeg`.

Targets with generated files and a build that has been run here: Linux (x86_64, aarch64), Android (x86_64, aarch64), Windows (x86_64, aarch64) and MacOS (x86_64, aarch64); only Linux x86_64 and Android (on the emulator) have also been run. The iOS targets (device, and simulator on arm64 and x86_64) are defined the same way but can only be built and generated on a Mac with Xcode: elsewhere the build stops with a message naming the iOS SDK. Nothing for iOS has been built or run yet. The core library, including the AWS SDK for C and aws-lc, is defined for the iOS targets (device and both simulators, with the iOS SDK from `xcrun`) and for Windows aarch64, which builds from Linux.

## Messages from the libraries

Neither library prints to the process's standard error. What they say goes into the error of a call that failed, and to the log for a call that worked.

- ImageMagick: each call gives ImageMagick an `ExceptionInfo` of its own and reads the call's warnings and errors back out of it. A call that fails throws them; the warnings of a call that worked go to `log.tool` as `magick` output, with the operation and the file in front. ImageMagick's warning and error handlers, which are the process's, are left as ImageMagick sets them: MagickCore calls them only through `CatchException`, which nothing here calls.
- FFmpeg reports everything through one log callback for the whole process (`av_log_set_callback`), which FFmpeg keeps in an atomic. Every function sets it, to the same function, before it makes any context, so whichever runs first sets it and a second setting stores the same pointer again. The callback keeps nothing and shares nothing: it finds where a message belongs through the context FFmpeg logs it about, whose `opaque` field (left to the caller on FFmpeg's format, codec and scaling contexts) the call that made the context set to a message queue of that call's own. FFmpeg may log on a thread of its own (a decoder's frame threads, which carry a copy of the codec context and its `opaque`), so the message goes through the queue as a copy of its text, and the calling thread takes the messages out when every context of the call has been freed. A call that fails throws its warnings and errors after its own error; a call that worked sends errors to the log's errors and warnings to `log.tool` as `ffmpeg` output. A message about a context FFmpeg made for itself (the decoders `avformat_find_stream_info` opens to look at a stream) cannot be tied to a call: it goes to the console when it is an error, and is dropped otherwise.

## iOS

The ImageMagick and FFmpeg files for the iOS targets are not checked in: they come from the SDK of the Mac doing the build. Make them with the two `generate-config.sh` scripts (`aarch64-ios` for a device, `aarch64-ios-simulator` for the simulator on an arm64 Mac), then build each library in its `third-party` directory for the target (`zig build -Dtarget=aarch64-ios.14.0`). The iOS scripts (`apps/photosphere/scripts/sync-ios.sh`, and so `build-ios.sh`, `package-ios.sh` and `open-ios.sh`) link what those builds installed. The iOS release workflow does both through the library build actions.

## The old mobile apps (deprecated)

The Capacitor apps (`apps/android-frontend`, `apps/ios-frontend`) still use prebuilt ImageMagick libraries and the FFmpegKit forks described in `scripts/fetch-mobile-media-tools.sh` and `apps/ios-frontend/ios/build-imagemagick.sh`. They are removed later and are not changed by the work above.

## Licensing

See `THIRD-PARTY-NOTICES.md` and the README.
