# Updating the bundled ImageMagick and ffmpeg (mobile)

> Most of the steps below are automated by `scripts/update-mobile-media-tools.sh` (see `scripts/update-mobile-media-tools.md`). This document is the background and the manual reference.

The mobile apps bundle their own ImageMagick and ffmpeg. Desktop/CLI use the system-installed binaries and are not affected by anything here. When upstream releases a new version, update the four bundles below. The shared TypeScript argv contract (`packages/mobile-worker/src/lib/media-commands.ts`) uses standard CLI flags and normally needs no change; only revisit it if a major release changes CLI semantics of a flag we use (`-resize`, `-quality`, `-kmeans`, `-format`, `info:`, ffmpeg `-vf scale`, `-q:v`).

After any update, always re-run: `bun run test` (the mobile-worker suite proves the argv is still built as expected), then the native checks in the "Verify after updating" section.

## 1. ImageMagick on iOS (built from source)

The iOS ImageMagick static libraries are built by `apps/ios-frontend/ios/build-imagemagick.sh`.

1. Edit the version variables at the top of that script: `IM_VERSION` (e.g. `7.1.1-43` -> the new tag), and `JPEG_URL` / `PNG_URL` if you also want newer delegates.
2. Rebuild: `bun run vendor:imagemagick:ios` (macOS + Xcode command-line tools). It reinstalls into `apps/ios-frontend/ios/App/vendor/im/{device,sim}` (git-ignored).
3. If the quantum depth or HDRI setting changed, the static-library filename suffix changes (currently `Q8HDRI`, from `--with-quantum-depth=8 --enable-hdri`). Update the App target's `OTHER_LDFLAGS` to match: `-lMagickWand-7.<SUFFIX> -lMagickCore-7.<SUFFIX> -ljpeg -lpng16 -lz`, and keep `OTHER_CFLAGS` `-DMAGICKCORE_QUANTUM_DEPTH` / `-DMAGICKCORE_HDRI_ENABLE` consistent.
4. Clean-build the app so the new headers/libs are picked up.

## 2. ImageMagick on Android (prebuilt shared libraries)

Android uses prebuilt `.so` files plus vendored headers; the JNI shim (`apps/android-frontend/android/app/src/main/cpp/run_magick.c`) and its `CMakeLists.txt` compile against them.

1. Get the new build. Either grab updated artifacts from the prebuilt source (`MolotovCherry/Android-ImageMagick7`) or rebuild it for the new ImageMagick tag.
2. Replace the shared libraries in `apps/android-frontend/android/app/src/main/jniLibs/<abi>/` (`libmagickcore-7.so`, `libmagickwand-7.so`, and `libc++_shared.so` / `libomp.so` if they changed) for each ABI you ship (`arm64-v8a`, `x86_64`).
3. Replace the headers under `apps/android-frontend/android/app/src/main/cpp/imagemagick/include` and the per-ABI config overlays under `.../cpp/imagemagick/configs/<abi>`.
4. Keep the quantum depth consistent: `cpp/CMakeLists.txt` sets `-DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1`. If the new `.so` is built at a different quantum depth, update those defines to match, otherwise the shim and the library disagree and calls fail.
5. If the upstream soname (`libmagickcore-7.so` / `libmagickwand-7.so`) changes, update the `IMPORTED_LOCATION` paths and the `System.loadLibrary("magickcore-7"/"magickwand-7")` names in `ImageMagickRunner.java` to match.

## 3. ffmpeg on iOS (FFmpegKit SPM fork)

iOS ffmpeg comes from the `ffmpeg-kit-full-spm` Swift Package (full variant, needed for the `mjpeg` screenshot encoder).

1. In Xcode: File > Packages > Update to Latest Package Versions, or open the package dependency and bump the pinned version/revision.
2. If you switch to a different fork, keep the `com.arthenica.ffmpegkit` API surface (the runner uses `FFmpegKit`/`FFprobeKit.execute(withArguments:)`, `getReturnCode().getValue()`, `getOutput()`), and confirm the build still includes `mjpeg`. `FfmpegKitRunner.swift` is gated on `#if canImport(ffmpegkit)`, so an absent package silently disables it.
3. Re-run the Embed Frameworks phase / clean-build so the new `.framework`s are copied into the app bundle.

## 4. ffmpeg on Android (FFmpegKit Maven fork)

Android ffmpeg comes from a Maven-published FFmpegKit fork, currently `com.moizhassan.ffmpeg:ffmpeg-kit-16kb`.

1. Bump the version in `apps/android-frontend/android/app/build.gradle`: `implementation 'com.moizhassan.ffmpeg:ffmpeg-kit-16kb:<new-version>'`.
2. If you switch forks, keep the `com.arthenica.ffmpegkit` package API (`FFmpegKit`/`FFprobeKit.executeWithArguments`, `getReturnCode().getValue()`, `getOutput()`). `FfmpegKitRunner.java` reaches these by reflection, so it compiles whether or not the dependency resolves, but at runtime the fork must expose that exact API and include the codecs used (notably `mjpeg`) and be 16KB-page-aligned for Android 15/16.
3. Sync Gradle and rebuild.

## Verify after updating

- `bun run test` — mobile-worker argv/marshalling suite still green.
- `bun run test:android:unit` and `bun run build:android` — Android wiring compiles.
- `bun run test:ios:unit` and `bun run build:ios` — iOS wiring compiles and the AppTests pass.
- `bun run test:android` / `bun run test:ios` — the on-emulator/simulator asset-processing smoke run (imports a sample image/video and checks the derivatives), which is the real end-to-end proof that the new binaries work.

## Update the licence notices

Whenever a bundled version changes, refresh the attribution so it stays accurate:

- `THIRD-PARTY-NOTICES.md` — the ImageMagick and ffmpeg versions, forks, and delegate library versions/licences.
- `README.md` — the "Bundled tools and licences" note if anything user-facing changed.
- `.github/workflows/release.yml` — the "Bundled tools and licences" block in the release-notes `body:` if the licence terms changed.

## Notes and gotchas

- ffmpeg licence: confirm each fork's build is LGPL (not GPL) and note any patent-encumbered codecs enabled, before shipping. The upstream `arthenica/ffmpeg-kit` was retired in 2025, which is why community forks are used; if a fork disappears, find a replacement exposing the same `com.arthenica` API.
- The screenshot path needs an `mjpeg` (JPEG) encoder in the ffmpeg build; a "min"/"lite" variant may omit it.
- Keep the iOS and Android ImageMagick quantum depths as they are unless you have a reason to change them; a mismatch between the compiled library and the `-D` defines is the most common cause of a silent failure after an update.
