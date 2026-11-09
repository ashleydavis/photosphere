# Review of ImageMagick and FFmpeg in the Zig CLI and the Photosphere App

How the Zig CLI (`apps/cli-zig`) and the Photosphere App use ImageMagick and FFmpeg, and the problems found. The findings come from reading the code. None of them has been reproduced by running anything.

## How it works

- `third-party/imagemagick` and `third-party/ffmpeg` build static libraries that are linked into both the CLI and the app.
  - ImageMagick is built with libjpeg, libpng and libwebp, and no HEIF delegate.
  - FFmpeg is configured as LGPL, with every decoder and demuxer, the file protocol, only the mjpeg encoder and a short list of filters.
- `packages-zig/media-tools-zig` calls the libraries' C interfaces in the program's own process, through functions that take typed arguments:
  - `image-magick.zig` calls MagickCore: `readImageInfo`, `readExif`, `resizeImage`, `transformImage`, `dominantColor` and `writeRgbImage`. Each call has an `ExceptionInfo` of its own, which its warnings and errors are read from.
  - `ffmpeg.zig` calls libavformat, libavcodec and libswscale: `probeFile`, `extractFrame`, `readPictureSize` and `decodePicture`. FFmpeg's log reaches the call it belongs to through the `opaque` field of the call's own contexts, which point at a message queue of the call's own.
- Nothing is set up or stopped. Each function can be called first, on any thread:
  - ImageMagick is started by `MagickCoreGenesis`, its own once-only step, which every function calls first, and the first call applies the security policy, read back from ImageMagick to tell whether it is applied.
  - FFmpeg needs no start; each function sets FFmpeg's log callback, the same one every time, before it makes a context.
- Callers in `packages-zig/tools-zig` call these functions directly; no command line is built or parsed.

### What uses the tools

- Images (`tools-zig/src/lib/image.zig`):
  - `readImageInfo` for width and height, and `readExif` for EXIF.
  - Resize to display, then thumbnail, then micro, each made from the one before (`node-api-zig/src/lib/image.zig`, `getImageDetails`).
  - Dominant colour from a 1x1 resize (`media-file-database.zig`, `extractDominantColorFromThumbnail`).
  - Rotate and flip from the EXIF orientation (`transform`).
- Videos (`tools-zig/src/lib/video.zig`):
  - `probeFile` for size, duration, frame rate, bitrate, codecs and creation time.
  - `extractFrame` for one screenshot at half the duration, capped at 300 seconds, which is then resized for the thumbnail.
- HEIC (`tools-zig/src/lib/heic.zig`):
  - `readPictureSize` for the size, since ImageMagick cannot read HEIC.
  - `decodePicture` decodes it to a JPEG, which ImageMagick then works on.
- Tool checks: `tools`, `version` and `bug` in the CLI, `ensureMediaProcessingTools` before `init`, `info` and `upgrade`, and the app's `check-tools` message.

## Inefficiencies

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
