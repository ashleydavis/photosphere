# Photosphere App

This is the Photosphere app for Windows, MacOS, Linux, Android and iOS, built on Ziggy. Ziggy is the application framework, in [its own repository](https://github.com/ashleydavis/ziggy): it shows the shared user interface (`packages/user-interface`) in the web view that each platform provides, and everything else is Zig. See [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/architecture.md) for how the parts fit together, the rules for adding a message type, a task type or a native host callback, and the protocol, and [Photosphere on Ziggy](../../docs/photosphere-on-ziggy.md) for how the app takes Ziggy from the local checkout beside this repository.

## Build tools

The `build.zig` at the root of the repository builds the core library for every target, including the Android shared library, and the Windows and Linux native apps. A second tool is used only where the platform forces it: Gradle packages the Android APK, `xcodebuild` builds the Swift iOS and MacOS apps, and Vite builds the frontend.

## Commands

Every command is a `package.json` script in `apps/photosphere`, run with `bun run --filter=ziggy <command>`. The root `package.json` mirrors the platform commands as `<job>:ziggy:<platform>`, for example `bun run build:ziggy:linux` and `bun run sync:ziggy:ios`. The run commands are the exception: they are at the root under their plain names, `bun run linux`, `bun run windows`, `bun run macos`, `bun run ios` and `bun run android`. Run them with `bun run`, never by calling the shell script directly. The tool versions are pinned by `mise.toml`, so run `mise install` once from the repository root. Every script has a markdown file beside it in `scripts` that describes its arguments.

| Command | What it does | Runs on |
|---|---|---|
| `setup` | Runs `setup:android` and `setup:ios` where they apply, `setup:windows` under Git Bash on Windows, and skips them where they do not. This is the script the root `bun run setup` fans out to | Any |
| `setup:android`, `setup:ios`, `setup:windows` | Installs what the platform build needs. `setup:ios` only checks Xcode and `simctl` and installs nothing. `setup:windows` fetches the WebView2 SDK and the WiX Toolset and installs Microsoft's C++ toolchain when it is missing. Linux needs only `mise install` | Android: Linux, MacOS. iOS: MacOS. Windows: Windows |
| `fetch:webview2`, `fetch:wix` | Downloads the pinned WebView2 SDK and the WiX Toolset into `apps/photosphere` (gitignored), which `setup:windows` runs. `fetch:webview2` is also what a Linux machine runs before checking that the Windows native app compiles | Any |
| `bundle:ui` | Builds the frontend into `apps/photosphere-frontend/dist` | Any |
| `bundle:core -- <target>` | `zig build` of the core for one target, from the root of the repository. This command, `sync:*` and `build:*` take an optional `--test-hooks` argument that builds the test hooks in, for the test and stories scripts; `package:*` never includes them | Linux, Windows and MacOS, except the MacOS and iOS targets, which build on MacOS only (iOS needs Xcode's SDK) |
| `sync:android`, `sync:ios`, `sync:macos`, `sync:windows`, `sync:linux` | Builds the core and the frontend for the platform and copies them into its native project, so the project is current when opened or built | Android: Linux, MacOS. Linux: Linux. Windows: Windows. iOS and MacOS: MacOS |
| `build:linux`, `build:windows` | Sync, then `zig build` of the native app from the root of the repository | Linux: Linux. Windows: Windows |
| `build:android` | Sync, then Gradle builds the APK | Linux, MacOS |
| `build:macos`, `build:ios` | Sync, then `xcodebuild` | MacOS |
| `package:linux`, `package:windows`, `package:macos`, `package:android`, `package:ios` | Build, then produce the artifacts to distribute, unsigned. Linux: a `deb` (`dpkg-deb`) and a `zip`. Windows: an MSI installer (WiX Toolset) and a `zip`. MacOS: a `dmg` (`hdiutil`) and a `zip`. Android: an APK per architecture, built with `ReleaseSafe`. `package:android` takes `--version-name` and `--version-code`, `package:ios` takes `--version`. iOS: an archive from `xcodebuild archive` and an unsigned `ipa`. Each lands in `apps/photosphere/out/<platform>`, named `photosphere-<version>-<os>-<arch>.<ext>` (`linux`, `windows`, `macos`, `android` or `ios` for the OS part) | The platform's build row: Linux, Windows, MacOS for MacOS and iOS, Linux or MacOS for Android. The `dmg` needs MacOS and the MSI needs the WiX Toolset from `fetch:wix` |
| `distribute:android` | Builds the arm64 APK with `package:android` and uploads it to Firebase App Distribution for the tester group. Takes `--groups`, `--project`, `--version-name` and `--build-only`; see [distribute-android.md](scripts/distribute-android.md) and [Delivering the Android app to testers](../../docs/android-tester-distribution.md). Also `bun run distribute:ziggy:android` from the repository root | Linux or MacOS, with the Firebase CLI signed in |
| `linux`, `windows`, `macos`, `android`, `ios` | Builds, then launches the app (on an emulator, simulator or device for mobile) | `linux` on Linux, `windows` on Windows, `macos` and `ios` on MacOS, `android` on Linux or MacOS |
| `open:android`, `open:ios`, `open:macos`, `open:windows`, `open:linux` | Sync, then opens the native project in Android Studio or Xcode, or the project folder in the editor for Windows and Linux | Android and Linux: Linux, MacOS. Windows: Windows, Linux. iOS and MacOS: MacOS |
| `clean`, `clean:android`, `clean:ios`, `clean:linux`, `clean:macos`, `clean:windows` | Removes the build output of every platform, or of one. Gradle's and `xcodebuild`'s own clean for Android, iOS and MacOS, and one named file at a time for the rest | `clean`: any. `clean:ios` and `clean:macos`: MacOS |
| `stories:ziggy`, `stories:ziggy:and`, `stories:ziggy:ios` | Cycle the app through every UI story and capture screenshots, on the host operating system, the Android emulator or device, and the iOS simulator. The phone runs show whether pages fit a small screen. Defined in the root `package.json`; see the [stories README](../../packages/user-interface/src/stories/README.md) | Host: any desktop. Android: Linux, MacOS. iOS: MacOS |

Every platform has its own native project under `native/`, and every project is built from a copy of the core and the frontend placed inside it. `sync` puts the copy there, so the project is current whether it is built from the command line or opened in an IDE or editor.

## Tests

- Zig: `zig build test` at the root of the repository, which runs the tests of every Zig package, Ziggy, the example and the CLI.
- TypeScript: the pure functions in `apps/photosphere-frontend/src/lib` have unit tests in `apps/photosphere-frontend/src/test`. React components, contexts and hooks are not unit tested.
- Smoke tests: `bun run test:ziggy` on the host operating system, `bun run test:ziggy:and` on the Android emulator pool or a device, and `bun run test:ziggy:ios` on the iOS simulator or a connected iOS device (MacOS only), from the repository root. See [`apps/photosphere-smoke-tests`](../photosphere-smoke-tests/README.md).
