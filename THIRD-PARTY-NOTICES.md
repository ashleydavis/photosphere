# Third-party notices

Photosphere bundles third-party software with its **mobile applications** (iOS and Android) so that image and video processing works in-process without system-installed binaries. The desktop and CLI builds do **not** bundle these tools: they use ImageMagick and ffmpeg installed on the host system.

This file lists the bundled components and their licences. It must be kept up to date when the bundled versions or forks change.

## ImageMagick

- Component: ImageMagick (in-process static/shared library)
- Used on: iOS (static libraries built from source), Android (prebuilt shared libraries)
- Android prebuilt source: [MolotovCherry/Android-ImageMagick7](https://github.com/MolotovCherry/Android-ImageMagick7)
- Licence: The ImageMagick licence, an Apache-2.0-style licence. See <https://imagemagick.org/script/license.php>.
- Copyright: © 1999 ImageMagick Studio LLC, a non-profit organization dedicated to making software imaging solutions freely available.

ImageMagick bundles the following delegate libraries:

- **libjpeg** (Independent JPEG Group / libjpeg-turbo) — IJG licence / BSD-style. <https://libjpeg-turbo.org/>
- **libpng** — PNG Reference Library License (zlib/libpng style). <http://www.libpng.org/pub/png/src/libpng-LICENSE.txt>
- **zlib** — zlib licence. <https://zlib.net/zlib_license.html>

## ffmpeg

- Component: ffmpeg / ffprobe (in-process, via FFmpegKit forks)
- iOS fork: `ffmpeg-kit-full-spm` (Swift Package Manager distribution of a community FFmpegKit fork)
- Android fork: `com.moizhassan.ffmpeg:ffmpeg-kit-16kb` (16KB-page-aligned community FFmpegKit fork)
- Licence: ffmpeg as built by these forks is distributed under the **GNU Lesser General Public License, version 2.1 or later (LGPL-2.1+)**. The full LGPL text is available at <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.
- Copyright: © the FFmpeg project and contributors. <https://ffmpeg.org/>

> Note: the original `arthenica/ffmpeg-kit` project was retired and its prebuilt binaries were removed in 2025, which is why Photosphere uses the community forks named above. The exact LGPL-vs-GPL status and the set of enabled (and potentially patent-encumbered) codecs depend on how each fork's ffmpeg is configured; confirm the configuration of the pinned fork versions before a public release and update this file accordingly.

## Attribution

The LGPL components are dynamically loadable libraries shipped alongside the application, and this notices file (distributed with releases) provides the required attribution and licence text references. The ImageMagick and delegate-library notices above satisfy their respective attribution requirements.
