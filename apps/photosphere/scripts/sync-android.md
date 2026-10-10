# sync-android.sh

Builds what the Android app packages and puts it where Gradle expects it, under `shells/android/app/build/ziggy`. Gradle never runs `zig`: this script does, and the Gradle build fails with a message naming this script when its output is missing.

Invoke: `bun run --filter=ziggy sync:android -- [options]`

- `--arch "<list>"`: the architectures to build, `x86_64` and `arm64`, space separated, or `all`. The default is both.
- `--optimize <mode>`: the Zig optimize mode, `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. The default is `ReleaseSafe`.
- `--test-hooks`: compile in the test hooks (the test control connection). Never for a release.
- `--skip-ui`: do not rebuild the page. `apps/photosphere-frontend/dist/index.html` must already exist.

What it does:

0. Fetches ImageMagick (`scripts/fetch-mobile-media-tools.sh android`), which the app runs inside its own process because Android has no `magick` program. The libraries and headers go into git-ignored directories of `apps/android-frontend` and the Photosphere Android project links and packages them from there; the fetch skips what is already present. ffmpeg and ffprobe come from the FFmpegKit Maven dependency, with no fetch.
1. Writes a libc file per architecture from the NDK's sysroot. Zig has no C library for Android, so `zig build --libc <file>` is given the NDK's headers and libraries (the ones for the app's minimum SDK level).
2. Builds `libphotosphere.so` per architecture with the `photosphere-core` step of the root `build.zig` (`zig build photosphere-core -Dtarget=<arch>-linux-android`) and copies it to `jniLibs/<abi>/`. A library of an architecture not asked for is removed, by name.
3. Builds the page (`bun run bundle:ui`) before the library, because the library embeds it. The library is where the shell finds the page, so nothing of the page goes into the assets.
4. Deletes the page and inject script copies that earlier versions of this script put in the assets, because the library holds both now.
