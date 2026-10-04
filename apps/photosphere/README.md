# Photosphere App

This is the Photosphere app for Windows, MacOS, Linux, Android and iOS, built on Ziggy. Ziggy is the application shell: it shows the shared user interface (`packages/user-interface`) in the web view that each platform provides, and everything else is Zig. See [Ziggy architecture](../../packages/ziggy/docs/architecture.md) for how the parts fit together, the rules for adding a channel, a task type or a native host callback, and the protocol.

## Build tools

The build in `packages-zig/photosphere-core` builds the core library for every target, including the Android shared library. The Windows and Linux shells are each a Zig package with its own `build.zig`. A second tool is used only where the platform forces it: Gradle packages the Android APK, `xcodebuild` builds the Swift iOS and MacOS apps, and Vite builds the UI.

## Commands

Every command is a `package.json` script in `apps/photosphere`, run with `bun run --filter=ziggy <command>`. The root `package.json` mirrors each as `<job>:ziggy:<platform>`, for example `bun run build:ziggy:linux`, `bun run run:ziggy:android` and `bun run sync:ziggy:ios`. Run them with `bun run`, never by calling the shell script directly. The tool versions are pinned by `mise.toml`, so run through `mise exec --` where your shell does not pick them up.

| Command | What it does | Runs on |
|---|---|---|
| `setup` | Runs `setup:android` and `setup:ios` where they apply and skips them where they do not. This is the script the root `bun run setup` fans out to | Any |
| `setup:android`, `setup:ios` | Installs what the platform build needs. Windows and Linux need only `mise install` | Android: Linux, MacOS. iOS: MacOS |
| `bundle:ui` | Builds the UI into `apps/photosphere-frontend/dist` | Any |
| `bundle:core -- <target>` | `zig build` of the core for one target. This command, `sync:*` and `build:*` take an optional `--test-hooks` argument that builds the test hooks in, for the test and stories scripts; `package:*` never includes them | Linux, Windows and MacOS, except the MacOS and iOS targets, which build on MacOS only |
| `sync:android`, `sync:ios`, `sync:macos`, `sync:windows`, `sync:linux` | Builds the core and the UI for the platform and copies them into its native project, so the project is current when opened or built | Android and Linux: Linux, MacOS. Windows: Windows, or cross-compiled from Linux. iOS and MacOS: MacOS |
| `build:linux`, `build:windows` | Sync, then `zig build` in the shell project | Linux; Windows, or cross-compiled from Linux |
| `build:android` | Sync, then Gradle builds the APK | Linux, MacOS |
| `build:macos`, `build:ios` | Sync, then `xcodebuild` | MacOS |
| `package:linux`, `package:windows`, `package:macos`, `package:android`, `package:ios` | Build, then produce the artifacts to distribute, unsigned. Linux: a `deb` (`dpkg-deb`) and a `zip`. Windows: an installer (NSIS) and a `zip`. MacOS: a `dmg` (`hdiutil`) and a `zip`. Android: the APK. iOS: an archive from `xcodebuild archive`. Each lands in one output folder per platform, named `photosphere-<version>-<os>-<arch>.<ext>` | The platform's build row: Linux, Windows (or cross-compiled from Linux), MacOS for MacOS and iOS, Linux or MacOS for Android. The `dmg` needs MacOS and the NSIS installer needs `makensis` |
| `run:linux`, `run:windows`, `run:macos`, `run:android`, `run:ios` | Builds, then launches the app (on an emulator, simulator or device for mobile) | `run:linux` on Linux, `run:windows` on Windows, `run:macos` and `run:ios` on MacOS, `run:android` on Linux or MacOS |
| `open:android`, `open:ios`, `open:macos`, `open:windows`, `open:linux` | Sync, then opens the native project in Android Studio or Xcode, or the project folder in the editor for Windows and Linux | Android and Linux: Linux, MacOS. Windows: Windows, Linux. iOS and MacOS: MacOS |
| `clean` | Removes the build output of every platform | Any |
| `stories:ziggy`, `stories:ziggy:and`, `stories:ziggy:ios` | Cycle the app through every UI story and capture screenshots, on the host operating system, the Android emulator or device, and the iOS simulator. The phone runs show whether pages fit a small screen. Defined in the root `package.json`; see the [stories README](../../packages/user-interface/src/stories/README.md) | Host: any desktop. Android: Linux, MacOS. iOS: MacOS |

Every platform has its own native project under `shells/`, and every project is built from a copy of the core and the UI placed inside it. `sync` puts the copy there, so the project is current whether it is built from the command line or opened in an IDE or editor.

## Tests

- Zig: `zig build test` in `packages-zig/photosphere-core`, plus the package tests of every Zig package touched.
- TypeScript: the pure functions in `apps/photosphere-frontend/src/lib` have unit tests in `apps/photosphere-frontend/src/test`. React components, contexts and hooks are not unit tested.
- Smoke tests: [`apps/photosphere-smoke-tests`](../photosphere-smoke-tests/README.md).
