# Third-party notices

The Photosphere App bundles third-party software on every platform (Windows, MacOS, Linux, Android and iOS). The Zig command line tool (`psi`) bundles the same ImageMagick and FFmpeg on Windows, MacOS and Linux. Both do so that image and video processing runs inside the program without anything installed on the machine. The old Electron desktop app, the old Capacitor mobile apps and the TypeScript command line tool use ImageMagick and ffmpeg installed on the host (the mobile apps carried their own builds, see below).

This file lists the bundled components and their licences. It must be kept up to date when the bundled versions change. The versions are in `third-party/*/vendor/*/VENDORED_VERSION`, and for zlib-ng, the AWS SDK for C, s2n-tls and aws-lc in the `build.zig.zon` of `third-party/zlib-ng` and `third-party/aws`.

## ImageMagick

- Component: ImageMagick, built from source into the app and the CLI as a static library and called in process.
- Licence: The ImageMagick licence, an Apache-2.0-style licence. See <https://imagemagick.org/script/license.php>.
- Copyright: © 1999 ImageMagick Studio LLC, a non-profit organization dedicated to making software imaging solutions freely available.

ImageMagick is built with the following delegate libraries, also built from source into the app and the CLI:

- **libjpeg** (Independent JPEG Group) — IJG licence. <https://www.ijg.org/>
- **libpng** — PNG Reference Library License (zlib/libpng style). <http://www.libpng.org/pub/png/src/libpng-LICENSE.txt>
- **libwebp** — BSD 3-clause licence, with a patent grant. <https://chromium.googlesource.com/webm/libwebp/+/refs/heads/main/COPYING>
- **zlib-ng** — zlib licence. <https://github.com/zlib-ng/zlib-ng>

## FFmpeg

- Component: FFmpeg (libavutil, libavcodec, libavformat, libavfilter, libswscale, libswresample) and the `ffmpeg` and `ffprobe` command line programs, built from source into the app and the CLI as a static library and called in process.
- Licence: configured without `--enable-gpl` and `--enable-nonfree`, so the **GNU Lesser General Public License, version 2.1 or later (LGPL-2.1+)**. This is what the built FFmpeg reports through `avutil_license()`: "LGPL version 2.1 or later", the `FFMPEG_LICENSE` its configure writes into `third-party/ffmpeg/config/<target>/config.h`. The licence text is at <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>. Linking it statically into the one app binary and into the CLI has consequences under the LGPL (each must let a user relink it with a modified FFmpeg); how they meet them is not yet decided.
- Copyright: © the FFmpeg project and contributors. <https://ffmpeg.org/>

## Old mobile apps (deprecated)

The old Capacitor mobile apps bundle ImageMagick (prebuilt shared libraries on Android from [MolotovCherry/Android-ImageMagick7](https://github.com/MolotovCherry/Android-ImageMagick7), static libraries built from source on iOS) and ffmpeg through the community FFmpegKit forks `ffmpeg-kit-full-spm` (iOS) and `com.moizhassan.ffmpeg:ffmpeg-kit-16kb` (Android), under the same licences.
