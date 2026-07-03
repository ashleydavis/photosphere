# Mobile native ImageMagick and ffmpeg

The mobile apps run image/video asset operations in-process through three `host.*` bridge functions: `host.imageMagick`, `host.ffmpeg`, `host.ffprobe`. The shared TypeScript builds the argv (see `packages/mobile-worker/src/lib/media-commands.ts`) and the native side runs it against bundled ImageMagick and ffmpeg. Desktop and CLI are unchanged and keep using system-installed binaries.

The native source and wiring are committed and compile without the native binaries: the runners report "not linked" until the libraries are vendored and activated. The steps below activate them and must be run on the appropriate toolchain (they cannot run in a Linux CI without Xcode / the Android NDK and network access to fetch the binaries).

## iOS (Phase B)

Files: `apps/ios-frontend/ios/App/App/JsEngine/{run_magick.c,run_magick.h,MediaToolRunner.swift,ImageMagickRunner.swift,FfmpegKitRunner.swift}`, the bridge installs in `HostBridge.swift`, the bridging header `App/App-Bridging-Header.h`, and the build script `ios/build-imagemagick.sh`.

1. Build ImageMagick static libraries (device arm64 + simulator) on macOS:
   `bash apps/ios-frontend/ios/build-imagemagick.sh`
   This installs headers/libs under `apps/ios-frontend/ios/App/vendor/im/{device,sim}` (git-ignored).
2. In the App target build settings, point `HEADER_SEARCH_PATHS` and `LIBRARY_SEARCH_PATHS` at the matching `vendor/im` slice, add `OTHER_LDFLAGS = -lMagickWand-7.Q8HDRI -lMagickCore-7.Q8HDRI -ljpeg -lpng16 -lz`, and add `IMAGEMAGICK_LINKED` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
3. Add the FFmpegKit SPM package `ffmpeg-kit-full-spm` (full variant, for the `mjpeg` screenshot encoder) and its "Embed Frameworks" run-script phase. `FfmpegKitRunner` activates automatically via `#if canImport(ffmpegkit)`.

## Android (Phase C)

Files: `apps/android-frontend/android/app/src/main/cpp/{run_magick.c,CMakeLists.txt}`, the runners and bridge in `.../jsengine/`.

1. Vendor the prebuilt `MolotovCherry/Android-ImageMagick7` shared libs (`libmagickcore-7.so`, `libmagickwand-7.so`, `libc++_shared.so`, and `libomp.so` if present) into `app/src/main/jniLibs/<abi>/` for `arm64-v8a` (release) and `x86_64` (emulator/CI), and the ImageMagick headers + per-ABI config overlays under `app/src/main/cpp/imagemagick/`.
2. In `app/build.gradle`: wire `externalNativeBuild` (CMake 3.22.1, `cpp/CMakeLists.txt`), `ndkVersion "25.1.8937393"`, `-DANDROID_STL=c++_shared`, `abiFilters 'x86_64', 'arm64-v8a'`, and `packagingOptions.jniLibs.pickFirsts += ['**/libc++_shared.so']`. `ImageMagickRunner` loads the libs at runtime.
3. Add `implementation 'com.moizhassan.ffmpeg:ffmpeg-kit-16kb:6.1.1'`. `FfmpegKitRunner` reaches the API by reflection, so it activates once the dependency is on the classpath.
4. In `variables.gradle`, ensure `minSdkVersion >= 24` and the Android Gradle Plugin supports 16KB-aligned libs.

## Updating the bundled versions

To move to newer ImageMagick/ffmpeg releases, see [updating-mobile-imagemagick-ffmpeg.md](updating-mobile-imagemagick-ffmpeg.md) and the helper `scripts/update-mobile-media-tools.sh`.

## Licensing

The bundled ImageMagick and ffmpeg builds and their delegates are attributed in `THIRD-PARTY-NOTICES.md`, `README.md`, and the release-notes body in `.github/workflows/release.yml`.
