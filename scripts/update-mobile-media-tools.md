# update-mobile-media-tools.sh

Updates the ImageMagick and ffmpeg builds bundled into the mobile apps. Desktop and CLI use the system-installed binaries and are unaffected. Full background is in [docs/updating-mobile-imagemagick-ffmpeg.md](../docs/updating-mobile-imagemagick-ffmpeg.md); this is the quick reference for the script.

Each step is opt-in via a flag, so you can update one tool or platform at a time. Run with no arguments (or `--help`) to print usage.

## What it updates

There are four bundles. The script automates the deterministic parts of each:

| Bundle | Flag(s) | Automated |
| --- | --- | --- |
| ImageMagick (iOS, from source) | `--imagemagick-version <tag>` `--build-ios` | Bumps the version in `apps/ios-frontend/ios/build-imagemagick.sh` and runs the build (macOS only). |
| ImageMagick (Android, prebuilt) | `--android-so-dir <dir>` `--android-headers-dir <dir>` | Copies `libmagick*.so` (+ `libc++_shared`/`libomp`) into `jniLibs/<abi>` and headers into `cpp/imagemagick/include`. |
| ffmpeg (Android, Maven) | `--android-ffmpeg-version <ver>` | Bumps the FFmpegKit version in `app/build.gradle`. |
| ffmpeg (iOS, Swift Package) | `--ios-ffmpeg-version <ver>` | Prints the Xcode steps only (Xcode owns package resolution). |

Extra flags: `--abis "<a> <b>"` (Android ABIs, default `arm64-v8a x86_64`), `--verify` (run unit + compile checks).

## Examples

```bash
# Bump and rebuild iOS ImageMagick from source (on macOS):
scripts/update-mobile-media-tools.sh --imagemagick-version 7.1.1-45 --build-ios

# Bump the Android ffmpeg version:
scripts/update-mobile-media-tools.sh --android-ffmpeg-version 6.2.0

# Drop in new Android ImageMagick binaries + headers you already extracted:
scripts/update-mobile-media-tools.sh --android-so-dir ~/im/lib --android-headers-dir ~/im/include

# Update everything, then run the checks:
scripts/update-mobile-media-tools.sh --imagemagick-version 7.1.1-45 --build-ios \
  --android-ffmpeg-version 6.2.0 --ios-ffmpeg-version 6.0.1 --verify
```

## What it does NOT do

- **Fetch the Android ImageMagick `.so`** — upstream release layout varies, so you extract the artifacts yourself and point `--android-so-dir` / `--android-headers-dir` at them.
- **Resolve the iOS Swift Package** — Xcode regenerates `Package.resolved`, so `--ios-ffmpeg-version` prints the steps instead of editing anything.
- **Update the licence notices** — after any version change, refresh `THIRD-PARTY-NOTICES.md`, `README.md`, and the notices block in `.github/workflows/release.yml`. The script reminds you at the end.

## Verifying

`--verify` runs the mobile-worker unit tests and the Android compile check, and the iOS unit tests when on macOS. The real end-to-end proof is the on-device smoke run, which needs the vendored binaries and an emulator/simulator:

```bash
bun run test:android   # or: bun run test:ios
```

## Gotcha

Keep the ImageMagick quantum depth consistent between the compiled library and the `-D` defines (`MAGICKCORE_QUANTUM_DEPTH` in `cpp/CMakeLists.txt` on Android; the `Q8HDRI` lib-name suffix and `OTHER_CFLAGS` on iOS). A mismatch after an update is the most common cause of a silent failure.
