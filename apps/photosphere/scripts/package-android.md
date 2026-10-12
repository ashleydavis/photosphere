# package-android.sh

Builds the release APK per architecture. Each is synced with `ReleaseSafe` and no test hooks, then built with `gradlew assembleRelease`. The release variant is signed with the debug key so that it installs; it is not a store build.

Invoke: `bun run --filter=ziggy package:android -- [--arch "<list>"] [--output-dir <dir>] [--version-name <name>] [--version-code <number>]`

- `--arch "<list>"`: `x86_64` and `arm64`, space separated, or `all`. The default is both.
- `--version-name <name>`: the version the APK reports, and the name in its file name, such as `1.2.3` for the tag `v1.2.3`. The default is the version in `apps/photosphere/package.json`.
- `--version-code <number>`: the whole number Android uses to tell a newer build from an older one, which has to go up with every build that replaces another on a phone. The default is 1.
- `--output-dir <dir>`: where the APKs go, relative to `apps/photosphere` when not absolute. The default is `apps/photosphere/out/android`.

The artifacts are named `photosphere-<version>-android-<arch>.apk`.

## Why ReleaseSafe

`ReleaseSafe` is what the app's other release builds use, and it is the only release mode that keeps Zig's runtime safety checks, so a bug stops the app with a message instead of corrupting data. `ReleaseSmall` was the example's choice with no reason recorded, and one run measured what it buys: the example's x86_64 APK was about 0.75 MB with `ReleaseSmall` and 1.1 to 1.2 MB with `ReleaseSafe` or `ReleaseFast`, this app's x86_64 APK was about 115 MB against 117 MB, and every mode started on an x86_64 emulator.
