# Updating the bundled ImageMagick and ffmpeg (mobile)

> No third-party ImageMagick binaries, source, or headers are committed. Android ImageMagick is pulled from downstream at build time by `scripts/fetch-mobile-media-tools.sh` (run automatically by `bun run sync`); iOS ImageMagick is built from source by the same script's `ios` mode. ffmpeg is a Maven (Android) / SPM (iOS) dependency. `scripts/update-mobile-media-tools.sh` (see `scripts/update-mobile-media-tools.md`) still helps with the iOS from-source build and version bumps. This document is the background and the manual reference.

The mobile apps bundle their own ImageMagick and ffmpeg. Desktop/CLI use the system-installed binaries and are not affected by anything here. When upstream releases a new version, update the four bundles below. The shared TypeScript argv contract (`packages/mobile-worker/src/lib/media-commands.ts`) uses standard CLI flags and normally needs no change; only revisit it if a major release changes CLI semantics of a flag we use (`-resize`, `-quality`, `-kmeans`, `-format`, `info:`, ffmpeg `-vf scale`, `-q:v`).

After any update, always re-run: `bun run test` (the mobile-worker suite proves the argv is still built as expected), then the native checks in the "Verify after updating" section.

## 1. ImageMagick on iOS (built from source)

The iOS ImageMagick static libraries are built by `apps/ios-frontend/ios/build-imagemagick.sh`.

1. Edit the version variables at the top of that script: `IM_VERSION` (e.g. `7.1.1-43` -> the new tag), and `JPEG_URL` / `PNG_URL` if you also want newer delegates.
2. Rebuild: `bun run vendor:imagemagick:ios` (macOS + Xcode command-line tools). It reinstalls into `apps/ios-frontend/ios/App/vendor/im/{device,sim}` (git-ignored).
3. If the quantum depth or HDRI setting changed, the static-library filename suffix changes (currently `Q8HDRI`, from `--with-quantum-depth=8 --enable-hdri`). Update the App target's `OTHER_LDFLAGS` to match: `-lMagickWand-7.<SUFFIX> -lMagickCore-7.<SUFFIX> -ljpeg -lpng16 -lz`, and keep `OTHER_CFLAGS` `-DMAGICKCORE_QUANTUM_DEPTH` / `-DMAGICKCORE_HDRI_ENABLE` consistent.
4. Clean-build the app so the new headers/libs are picked up.

## 2. ImageMagick on Android (fetched from downstream, nothing committed)

Android's `.so` and headers are not committed. `scripts/fetch-mobile-media-tools.sh android` (run automatically by `bun run sync`) downloads the prebuilt `MolotovCherry/Android-ImageMagick7` `.so` from its GitHub release into the git-ignored `jniLibs/<abi>/`, downloads the matching ImageMagick source for the API headers, and runs `configure` with the NDK per ABI to generate the per-ABI config headers. The JNI shim (`cpp/run_magick.c`) + `CMakeLists.txt` compile against those.

1. Bump `IM_VERSION` at the top of `scripts/fetch-mobile-media-tools.sh` to the new tag (it must exist both as a `MolotovCherry/Android-ImageMagick7` release and an `ImageMagick/ImageMagick` source tag so the `.so` and generated headers agree).
2. Delete the git-ignored artifacts so the next build refetches: `rm -rf apps/android-frontend/android/app/src/main/{jniLibs,cpp/imagemagick} apps/android-frontend/android/.media-fetch`.
3. Keep the quantum depth consistent: `cpp/CMakeLists.txt` sets `-DMAGICKCORE_QUANTUM_DEPTH=16 -DMAGICKCORE_HDRI_ENABLE=1`, and the fetch configures with `--with-quantum-depth=16 --enable-hdri`. If the release `.so` moves to a different quantum depth, change both to match, otherwise the shim and the library disagree and calls fail.
4. If the upstream soname (`libmagickcore-7.so` / `libmagickwand-7.so`) changes, update the `IMPORTED_LOCATION` paths in `CMakeLists.txt`, the `System.loadLibrary(...)` names in `ImageMagickRunner.java`, and the copy list in `scripts/fetch-mobile-media-tools.sh` to match.

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

Note: this AAR needs a recent D8 — the Android Gradle Plugin is pinned to `8.1.4` in `apps/android-frontend/android/build.gradle` because AGP 8.0 crashes with a D8 `NullPointerException` while dexing this fork. If you see that dexing error after changing the fork or AGP, keep AGP at 8.1+.

## Verify after updating

- `bun run test` — mobile-worker argv/marshalling suite still green.
- `bun run test:and:unit` and `bun run build:and` — Android wiring compiles.
- `bun run test:ios:unit` and `bun run build:ios` — iOS wiring compiles and the AppTests pass.
- `bun run test:and` / `bun run test:ios` — the on-emulator/simulator asset-processing smoke run (imports a sample image/video and checks the derivatives), which is the real end-to-end proof that the new binaries work.

## Update the licence notices

Whenever a bundled version changes, refresh the attribution so it stays accurate:

- `THIRD-PARTY-NOTICES.md` — the ImageMagick and ffmpeg versions, forks, and delegate library versions/licences.
- `README.md` — the "Bundled tools and licences" note if anything user-facing changed.
- `.github/workflows/release.yml` — the "Bundled tools and licences" block in the release-notes `body:` if the licence terms changed.

## Notes and gotchas

- ffmpeg licence: confirm each fork's build is LGPL (not GPL) and note any patent-encumbered codecs enabled, before shipping. The upstream `arthenica/ffmpeg-kit` was retired in 2025, which is why community forks are used; if a fork disappears, find a replacement exposing the same `com.arthenica` API.
- The screenshot path needs an `mjpeg` (JPEG) encoder in the ffmpeg build; a "min"/"lite" variant may omit it.
- Keep the iOS and Android ImageMagick quantum depths as they are unless you have a reason to change them; a mismatch between the compiled library and the `-D` defines is the most common cause of a silent failure after an update.
