# build-android.sh

Runs `sync-android.sh`, then `gradlew assembleDebug`. The APK is `native/android/app/build/outputs/apk/debug/app-debug.apk`.

Invoke: `bun run --filter=ziggy build:android -- [--arch "<list>"] [--optimize <mode>] [--minify] [--output-dir <dir>]`

- `--arch`, `--optimize` and `--minify` are passed to `sync-android.sh`, which describes them.
- `--output-dir <dir>`: also copies the APK to `<dir>/photosphere.apk` and each Zig library to `<dir>/jniLibs/<abi>/libphotosphere.so`, creating the directory. Give an absolute path, because a script run through `bun run --filter=ziggy` runs in `apps/photosphere`. Without it the APK stays only in the Gradle output directory. The smoke tests and CI build into a directory of their own with it.
