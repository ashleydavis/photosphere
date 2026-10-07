# sync-android.sh

Builds what the Android app packages and puts it where Gradle expects it, under `shells/android/app/build/ziggy`. Gradle never runs `zig`: this script does, and the Gradle build fails with a message naming this script when its output is missing.

Invoke: `mise exec -- bash apps/ziggy-example/scripts/sync-android.sh [options]`

- `--arch "<list>"`: the architectures to build, `x86_64` and `arm64`, space separated, or `all`. The default is both.
- `--optimize <mode>`: the Zig optimize mode, `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. The default is `ReleaseSafe`.
- `--test-hooks`: compile in the test hooks (the test control connection). Never for a release.
- `--skip-ui`: do not rebuild the page. `dist/index.html` must already exist.

What it does:

1. Writes a libc file per architecture from the NDK's sysroot. Zig has no C library for Android, so `zig build --libc <file>` is given the NDK's headers and libraries (the ones for the app's minimum SDK level). The Zig core's JNI code is translated from the NDK's own `jni.h` with the include directories read from the same file.
2. Builds `libziggy_example.so` per architecture with the `ziggy-example-core` step of the root `build.zig` (`zig build ziggy-example-core -Dtarget=<arch>-linux-android`) and copies it to `jniLibs/<abi>/`. A library of an architecture not asked for is removed, by name.
3. Builds the page (`bun run bundle:ui`) before the library, because the library embeds it. The library is where the shell finds the page, so nothing of the page goes into the assets.
4. Deletes the page and inject script copies that earlier versions of this script put in the assets, because the library holds both now.
