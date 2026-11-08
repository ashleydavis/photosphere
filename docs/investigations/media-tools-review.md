# Review of ImageMagick and FFmpeg in the Zig CLI and the Photosphere App

How the Zig CLI (`apps/cli-zig`) and the Photosphere App use ImageMagick and FFmpeg, and the problems found. The findings come from reading the code. None of them has been reproduced by running anything.

## How it works

- `third-party/imagemagick` and `third-party/ffmpeg` build static libraries that are linked into both the CLI and the app.
  - ImageMagick is built with libjpeg, libpng and libwebp, and no HEIF delegate.
  - FFmpeg is configured as LGPL, with every decoder and demuxer, the file protocol, only the mjpeg encoder and a short list of filters.
- `packages-zig/media-tools-zig` runs the tools in the program's own process:
  - `image-magick.zig` calls `MagickImageCommand` and `IdentifyImageCommand`, collects ImageMagick's messages from the exception and sets a security policy at start.
  - `ffmpeg.zig` calls the patched `ffmpeg_run` and `ffprobe_run`, which keep their state per run. FFmpeg's log goes through a per-run message queue to the calling thread's log.
- `MediaTools` is started once on the main thread:
  - CLI: `apps/cli-zig/index.zig`, in `main`.
  - App: `packages-zig/photosphere-core/src/lib/main-state.zig`, in `MainState.create`.
- A task on any thread runs the tools by calling them directly once `MediaTools` has started them; nothing is made per task or per thread.
- Callers in `packages-zig/tools-zig` pass the tool and an argument list to `runChecked` or `runLogged` in `packages-zig/media-tools-zig/src/lib/tool-run.zig`, which call `ImageMagick.runMagick`, `Ffmpeg.runFfmpeg` or `Ffmpeg.runFfprobe` directly.

### What uses the tools

- Images (`tools-zig/src/lib/image.zig`):
  - `identify` for width and height, and a second `identify` for EXIF.
  - Resize to display, then thumbnail, then micro, each made from the one before (`node-api-zig/src/lib/image.zig`, `getImageDetails`).
  - Dominant colour from a 1x1 resize (`media-file-database.zig`, `extractDominantColorFromThumbnail`).
  - Rotate and flip from the EXIF orientation (`transform`).
- Videos (`tools-zig/src/lib/video.zig`):
  - `ffprobe` JSON for size, duration, frame rate, bitrate, codecs and creation time.
  - `ffmpeg` for one screenshot at half the duration, capped at 300 seconds, which is then resized for the thumbnail.
- HEIC (`tools-zig/src/lib/heic.zig`):
  - `ffprobe` for the size, since ImageMagick cannot read HEIC.
  - `ffmpeg` decodes it to a JPEG, which ImageMagick then works on.
- Tool checks: `tools`, `version` and `bug` in the CLI, `ensureMediaProcessingTools` before `init`, `info` and `upgrade`, and the app's `check-tools` message.

## Inefficiencies

- **Slow video screenshots.** `Video.extractScreenshot` puts `-ss` after `-i`, so ffmpeg decodes from the start up to the seek point, which can be 300 seconds in. Putting `-ss` before `-i` seeks directly.
- **Wasted `identify` call.** `Image.getImageInfo` always runs a second `identify` for EXIF. For non-JPEG images `getImageDetails` uses only the dimensions, so that result is thrown away.
- **Extra full-size re-encode for rotated photos.** `transform` writes a full-resolution JPEG before the display resize. The `-flop` and `-rotate` could go into the resize command instead, which saves a decode, an encode and a lossy generation.
- **No reduced-size JPEG decode.** The resize does not pass `-define jpeg:size=WxH`, so large JPEGs are decoded at full size before being shrunk.

## Rule breaches and leftover code

- **A swallowed error.** `Image.getImageInfo` ignores EXIF errors (`else |_| { // Ignore EXIF errors }`). This breaks the rule that all failures must be noisy.
- **Leftovers from when the tools were installed separately.** `ensureMediaProcessingTools`, `check-tools`, the missing-tools data for the page and the "Not found" output in `version` all date from that time. The tools are now compiled in, so they cannot be missing.
- **Out-of-date comment.** "Serialize tool verification to avoid race conditions" in `tools-zig/src/lib/tool-verification.zig`.
- **JavaScript error text.** `video.zig` raises errors such as `"undefined is not an object (evaluating 'probeData.format')"`. These are copied from the TypeScript port and mean nothing to a Zig reader.

## Trade-offs worth deciding

- **Colour profiles.** `-strip` in the resize drops colour profiles along with XMP. Display P3 iPhone photos will get thumbnails with shifted colours.
- **ImageMagick security policy.** It denies a list of coders and allows every other one. Allowing only the formats the import accepts would be tighter.
- **FFmpeg attack surface.** FFmpeg is built with every decoder and demuxer, which is a large attack surface for files received over LAN share.
- **LGPL compliance.** `THIRD-PARTY-NOTICES.md` says how static linking meets the LGPL "is not yet decided".

## Fix

Items the human has said must be fixed.

- No one-time setup of ImageMagick and FFmpeg. Each should be a library function that can be called anywhere, at any time, with no setup. What stands in the way today, from the code's own comments: ImageMagick's `MagickWandGenesis`/`MagickWandTerminus`, its security policy and its warning and error handlers are process-wide, and so is FFmpeg's log callback (`av_log_set_callback`). `MediaTools.init` sets all of these.
- No shell-style command strings, formatted or parsed, anywhere. Replace them with proper library functions for images and videos (for example `resizeImage`, `createThumbnail`) that take typed arguments. That means calling ImageMagick's and FFmpeg's C APIs (MagickWand or MagickCore, and libavformat, libavcodec, libavfilter and libswscale) directly, instead of driving the `magick`, `ffmpeg` and `ffprobe` command-line programs in-process.
