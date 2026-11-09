# generate-config.sh

Runs FFmpeg's own `configure` and `make` for a target, with Zig as the C compiler, and keeps what the Zig build needs from the result in `config/<target>/`. FFmpeg's source file lists and its generated headers depend on its configuration, so they are made by FFmpeg's own build files and not written by hand. Run it for each target when FFmpeg is taken at a new version (`update-ffmpeg.md`).

```
third-party/ffmpeg/generate-config.sh <zig-target> [<libc-file>]
```

- `<zig-target>`: the target as Zig names it: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-android`, `aarch64-linux-android`, `x86_64-windows-gnu`, `aarch64-windows-gnu`, `x86_64-windows-msvc`, `x86_64-macos`, `aarch64-macos`, `aarch64-ios`, `aarch64-ios-simulator` or `x86_64-ios-simulator`. The iOS targets need Apple's iOS SDK (found with `xcrun` and given to the compiler as its sysroot), so they can only be generated on a Mac with Xcode. `x86_64-windows-msvc` (what the Photosphere App's Windows shell is built for) needs the Windows SDK's headers, so it can only be generated on Windows with Visual Studio or its Build Tools, in an MSYS2 shell with its make.
- `<libc-file>`: Zig's libc file for the Android NDK, which the Android targets need. `apps/photosphere/scripts/sync-android.sh` writes one for each ABI.

What it keeps in `config/<target>/`:

- `config.h`, `config_components.h`, `libavutil/avconfig.h` and `libavutil/ffversion.h`, the headers `configure` and `make` write.
- The lists of components `configure` writes as C source: the codec, parser, bitstream filter, demuxer, muxer, protocol and filter lists.
- The two resources of the command line programs, as C source `make` writes from the files under `fftools/resources`.
- `lists.txt`: a line for each source file of a library (the library, then the path under `third-party/ffmpeg/vendor/ffmpeg`) and for each source file of the `ffmpeg` and `ffprobe` programs (the program, then the path without its `.c`), read from the commands `make -n` prints.
- `flags.txt`: the preprocessor and optimisation flags of one compile command, a flag a line.
- `fftools-flags.txt`: the same for the command line programs' sources, which are built without `HAVE_AV_CONFIG_H`.
- `includes.txt`: the include directories under `third-party/ffmpeg/vendor/ffmpeg` that `configure` adds for what the C library lacks, a directory a line.

What is built is chosen in the script, which starts from `--disable-everything` and turns on only what the app uses, because every demuxer, decoder and parser reads files the app was handed: the `mov`, `matroska`, `avi`, `mpegps`, `mpegvideo`, `asf` and `dv` demuxers (MP4, MOV, M4V, 3GP, 3G2, HEIC and HEIF; MKV and WebM; AVI; MPG, MPEG and VOB, whose video codec `mpegps` finds through the raw `mpegvideo` demuxer; WMV; DV), the `h264`, `hevc`, `vp8`, `vp9`, `mpeg4`, `h263`, `mjpeg`, `mpeg1video`, `mpeg2video`, `prores`, `wmv1`, `wmv2`, `wmv3`, `vc1`, `msmpeg4v1`, `msmpeg4v2`, `msmpeg4v3` and `dvvideo` decoders, the WMA decoders `wmav1`, `wmav2` and `wmapro`, and the parsers `h264`, `hevc`, `vp8`, `vp9`, `mpeg4video`, `h263`, `mjpeg`, `mpegvideo` and `vc1`, the bitstream filters `configure` turns on for them (`vp9_superframe_split`), the file protocol, zlib (the zlib-ng the rest of the program is built over, built for the target by `zig build zlib`), and for output only the mjpeg encoder, the image2 muxer and a short list of filters. There is no other audio decoder, no external library but zlib, no hardware acceleration, no network and no devices, and neither `--enable-gpl` nor `--enable-nonfree` is given, so `configure` reports the license as LGPL version 2.1 or later. The script's comment says why each part is there.

It works under `tmp/ffmpeg-config/<target>/`, out of tree, and does not change `third-party/ffmpeg/vendor/ffmpeg`.
