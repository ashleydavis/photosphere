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
- Licence: configured without `--enable-gpl` and `--enable-nonfree`, so the **GNU Lesser General Public License, version 2.1 or later (LGPL-2.1+)**. This is what the built FFmpeg reports through `avutil_license()`: "LGPL version 2.1 or later", the `FFMPEG_LICENSE` its configure writes into `third-party/ffmpeg/config/<target>/config.h`. The licence text is FFmpeg's own `third-party/ffmpeg/vendor/ffmpeg/COPYING.LGPLv2.1`, also at <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.
- Version and build: the version is in `third-party/ffmpeg/vendor/ffmpeg/VENDORED_VERSION`. The configure options are in `third-party/ffmpeg/generate-config.sh`, and the exact configure command line for each target is recorded as `FFMPEG_CONFIGURATION` in `third-party/ffmpeg/config/<target>/config.h`.
- Changes: `third-party/ffmpeg/fftools-per-run-state.patch` changes the `ffmpeg` and `ffprobe` programs (FFmpeg's `fftools`) so that they keep their state per run, and every file it changes says so, with the date, in a comment at its top. Nothing else in FFmpeg is changed.
- Copyright: © the FFmpeg project and contributors. <https://ffmpeg.org/>

### How the LGPL is met

FFmpeg is linked statically into the Photosphere App on every platform and into the CLI. Section 6 of the LGPL 2.1 lets a program that is linked with an LGPL library be distributed under the program's own terms when every copy comes with the following, and this is how each is given:

- **A prominent notice that FFmpeg is used and is under the LGPL.** This file, and the "Bundled tools and licences" section of the notes of every GitHub release, which the release workflows (`.github/workflows/release-<platform>.yml`) write.
- **A copy of the LGPL.** Every package and archive the release workflows publish holds a `licences` folder, written by `scripts/write-licence-files.sh`: `COPYING.LGPLv2.1.txt` (the LGPL 2.1), `LICENSE.txt` (Photosphere's MIT licence), this file, `THIRD-PARTY-LICENCES.txt` (the licence texts of the vendored libraries) and `SOURCE.txt`. It is in the Linux zip and deb (`/opt/photosphere/licences`), the Windows zip and MSI (beside `photosphere.exe`), the MacOS dmg and zip (beside `Photosphere.app`, outside the signed app), the Android APK (`assets/licences`), the iOS .ipa (`Payload/Photosphere.app/licences`) and every CLI archive (beside the executable).
- **The means to change FFmpeg and relink the program with it.** The route taken is the source of the whole program, LGPL section 6(a), offered from the same place as the program, section 6(d). This repository is public, Photosphere's own code is under the MIT licence, which allows changing it and taking it apart, and the repository holds FFmpeg's source, the options it is configured with and every script that builds and packages the program. Every GitHub release is created by its workflow on the commit it was built from (`target_commitish` is that commit), its tag points at it, its notes name the commit and link to its source, and GitHub attaches the source archives of that commit to the release page the program is downloaded from. `SOURCE.txt` in every package names the same commit, and says how to build the program again with a changed FFmpeg. Object files for relinking, the other route of section 6(a), are not published.
- **Changed files are marked.** LGPL section 2 asks that a changed file says so, with the date. See Changes above.

Where Photosphere is distributed, and what that means for the LGPL:

- GitHub releases, from the release workflows: everything above applies.
- Android tester builds, through Firebase App Distribution (`apps/photosphere/scripts/distribute-android.sh`): the APK is made by the same `package-android.sh`, so it carries the `licences` folder. `SOURCE.txt` names the commit of the checkout it was built in, so that commit must be in the public repository before a build of it is handed out.
- Neither app store. The Android app is not on Google Play, and the iOS app is published only as an unsigned .ipa on GitHub releases, not through Apple's App Store or TestFlight. The App Store's terms of use add restrictions to what a user may do with an app, which the LGPL forbids adding, so distributing a build that contains FFmpeg through the App Store needs this question settled first.

This is an engineering reading of the licence, not legal advice.

## Old mobile apps (deprecated)

The old Capacitor mobile apps bundle ImageMagick (prebuilt shared libraries on Android from [MolotovCherry/Android-ImageMagick7](https://github.com/MolotovCherry/Android-ImageMagick7), static libraries built from source on iOS) and ffmpeg through the community FFmpegKit forks `ffmpeg-kit-full-spm` (iOS) and `com.moizhassan.ffmpeg:ffmpeg-kit-16kb` (Android), under the same licences.
