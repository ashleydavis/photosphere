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
- Each task makes a `ThreadTools` (`packages-zig/node-api-zig/src/lib/task-handlers.zig`, `withTools`).
- Callers in `packages-zig/tools-zig` build shell-style command strings such as `magick "path" -resize ...`. `exec` in `packages-zig/node-utils-zig/src/lib/exec.zig` hands them to `in-process-tools.zig`, where `splitCommand` parses them back into an argument list.

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

## Bug

- **File paths containing `$`, a backtick or `"` fail.**
  - Paths are put inside double quotes with no escaping in `tools-zig/src/lib/image.zig`, `video.zig` and `heic.zig`.
  - `splitCommand` throws on `$` and backtick inside double quotes, which its test `node-utils-zig/src/test/in-process-tools.test.zig` confirms (`magick "$HOME"`). A `"` in a path breaks the quoting.
  - So a file such as `Trip $5.jpg` would fail to import. This is inferred from the code and not reproduced.
  - On Windows, `\$` inside double quotes loses its backslash, so such a path is changed before it reaches the tool.
  - Fix: pass an argument list to the runner instead of building a string and parsing it again.

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

## `ThreadTools`

- `ThreadTools` (`media-tools-zig/src/lib/media-tools.zig`) is an empty struct. `init()` returns `.{}` and `runner()` returns an `InProcessRunner` whose `handles` and `run` ignore `context`.
- The interface needs a context pointer, because `FakeToolRunner` (`tools-zig/src/test/fake-tool-runner.zig`) uses it to record arguments. `taskEntries` takes a `Tools` type with `init()` and `runner()`, and the tests pass `NoTools` (`node-api-zig/src/test/test-environment.zig`).
- `ThreadTools` does not need any of that:
  - It has no state, so making one per thread achieves nothing.
  - The comment saying it "must not move while the runner is used" does not apply, because nothing reads the pointer.
  - The comments make an empty struct sound as if it guarded thread safety. The shared state that matters is in the C libraries (ImageMagick's setup and handlers, FFmpeg's log callback), and `MediaTools.init` starts it once.
- A simpler shape:
  - Replace `ThreadTools` with one constant `InProcessRunner` with `context = null`.
  - Have `taskEntries` take that runner value instead of a `Tools` type.
  - Have `MediaTools` keep only the start and stop of the libraries, without its `tools` field.
  - Callers to update: `task-handlers.zig`, `photosphere-core/src/index.zig`, `photosphere-core/src/lib/tools.zig`, `apps/cli-zig/src/lib/worker-pool.zig`, and the tests that call `ThreadTools.init()`.

## Removing `ThreadTools` and `InProcessRunner`

### Why they exist

- `media-tools-zig` is the only package that links libc and the ImageMagick and FFmpeg libraries. `tools-zig` and `node-api-zig` link neither and do not depend on `media-tools-zig` (see the package table in `build.zig`).
- `InProcessRunner` is the indirection that lets those two packages run the tools without linking them. The program hands a runner in from the top, and `taskEntries` takes a `Tools` type so the CLI and app pass `ThreadTools` while the `node-api-zig` tests pass `NoTools`.
- The string commands, `splitCommand` and the shell fallback in `exec` are left over from when the tools were separate programs.

### Proposal

- `tools-zig` depends on `media-tools-zig` and calls `ImageMagick.runMagick` and `Ffmpeg.runFfmpeg` / `runFfprobe` directly, with an argument list.
- Delete `InProcessRunner`, `ThreadTools`, `NoTools`, `in-process-tools.zig` (`splitCommand`, `tryRun`), the `Tools` parameter of `taskEntries`, and the `tools`/`toolRunner` parameter threaded through every caller (39 files mention `InProcessRunner`).
- `MediaTools` keeps only the start and stop of the libraries.
- This also fixes the path quoting bug above, since no string is parsed.

### Costs

- `tools-zig` and `node-api-zig` link libc, ImageMagick and FFmpeg, so their test binaries get larger and slower to build.
- The tests that use `FakeToolRunner` (`image.command.test.zig`, `video.probe.test.zig`, `tool-verification.test.zig`) assert command strings. They are replaced by tests that run the real tools on fixture files.
- The `node-api-zig` test environment, which runs tasks with no tools, runs them with the real tools. `MediaTools` has to be started in that environment.

## Trade-offs worth deciding

- **Colour profiles.** `-strip` in the resize drops colour profiles along with XMP. Display P3 iPhone photos will get thumbnails with shifted colours.
- **ImageMagick security policy.** It denies a list of coders and allows every other one. Allowing only the formats the import accepts would be tighter.
- **FFmpeg attack surface.** FFmpeg is built with every decoder and demuxer, which is a large attack surface for files received over LAN share.
- **LGPL compliance.** `THIRD-PARTY-NOTICES.md` says how static linking meets the LGPL "is not yet decided".

## Fix

Items the human has said must be fixed.

- Reconsider `ThreadTools` and `InProcessRunner` and try to remove them.
- No one-time setup of ImageMagick and FFmpeg. Each should be a library function that can be called anywhere, at any time, with no setup. What stands in the way today, from the code's own comments: ImageMagick's `MagickWandGenesis`/`MagickWandTerminus`, its security policy and its warning and error handlers are process-wide, and so is FFmpeg's log callback (`av_log_set_callback`). `MediaTools.init` sets all of these.
- No shell-style command strings, formatted or parsed, anywhere. Replace them with proper library functions for images and videos (for example `resizeImage`, `createThumbnail`) that take typed arguments. That means calling ImageMagick's and FFmpeg's C APIs (MagickWand or MagickCore, and libavformat, libavcodec, libavfilter and libswscale) directly, instead of driving the `magick`, `ffmpeg` and `ffprobe` command-line programs in-process.
