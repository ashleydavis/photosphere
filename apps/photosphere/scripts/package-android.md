# package-android.sh

Builds the release APK per architecture. Each is synced with `ReleaseSmall` and no test hooks, then built with `gradlew assembleRelease`. The release variant is signed with the debug key so that it installs; it is not a store build.

Invoke: `bun run --filter=ziggy package:android -- [--arch "<list>"] [--output-dir <dir>] [--version-name <name>] [--version-code <number>]`

- `--arch "<list>"`: `x86_64` and `arm64`, space separated, or `all`. The default is both.
- `--version-name <name>`: the version the APK reports, and the name in its file name. The default is the version in `apps/photosphere/package.json`.
- `--version-code <number>`: the whole number Android uses to tell a newer build from an older one, which has to go up with every build that replaces another on a phone. The default is 1.
- `--output-dir <dir>`: where the APKs go. The default is `apps/photosphere/out/android`.

The artifacts are named `photosphere-<version>-android-<arch>.apk`, with the version from `package.json`.
