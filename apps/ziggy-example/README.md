# Ziggy example

A small complete app built on Ziggy, kept as the reference for building an app on it. It has a page (TypeScript and HTML), a Zig core with its own channel handlers and task handlers, a native shell for each platform and smoke tests. It uses nothing of Photosphere's, and nothing in Ziggy knows about it, which is what keeps Ziggy usable for an app that is not Photosphere. See [Ziggy architecture](../../packages/ziggy/docs/architecture.md) for how the parts fit.

## What it shows

- The page asks the Zig core a question (`ping`) and shows the answer.
- Tasks: a short task, a long task that queues child tasks and waits for them, several long tasks at once, cancelling by source, and a task that fails. Output text, `job-progress` messages and every `task-message` and `task-completed` event appear in the page.
- The edges of the bridge: a multi-megabyte payload, text with quotes, newlines and non-ASCII characters, an error reply, and a file written and read in the app's private data directory.
- A native host callback: the page asks for the operating system's version, a task calls the shell's callback and the answer comes back to the page.
- File and folder pickers: three buttons ask the core for the native dialogs, on the same channels and with the same data and replies as the Electron app (`pick-files`, `pick-folder`, `pick-file`), and the page shows the paths chosen. A phone has no save dialog, so that button gives an error on iOS.
- A desktop menu defined once in Zig and drawn natively, with keyboard shortcuts that work anywhere in the window, and developer tools (Ctrl+Shift+I, or Cmd+Shift+I on a Mac) that open from it. A phone shows no menu.

## Where things are

Everything here is the example's own. Ziggy, the framework it is built on, is all in `packages/ziggy` (see its [README](../../packages/ziggy/README.md)), and nothing in this folder is shared with another app.

- `page/`: the page. `page/index.html` is the page and `page/src/lib` holds the plain functions that have unit tests. `vite.config.ts` is its build, which writes `dist` with relative paths and a classic script so it loads from a file address in every web view that loads it that way. `dist` is embedded in the app's own code on every platform (the Linux and Windows executables, and the core library that the MacOS, iOS and Android apps contain), using Ziggy's `embedPage`, so no platform has a folder of page files (see the [architecture guide](../../packages/ziggy/docs/architecture.md#the-bundled-page)).
- `core/`: the example's Zig library, which adds its channel handlers and task handlers to Ziggy's core (`packages/ziggy/core`).
- `shells/<platform>/`: the example's native project for each platform: its name, window, icon and the app's core and page packaged together. Each one builds on Ziggy's framework half for that platform in `packages/ziggy/native/<platform>` (MacOS and iOS share `packages/ziggy/native/apple`).
- `scripts`: the build, run and packaging scripts, each with a markdown file beside it.
- `smoke-tests`: the smoke test scenarios and a library for each platform. See `smoke-tests/run.md`.

## Commands

Run these from the repository root. `<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each platform's commands run on that platform (MacOS and iOS need a Mac with Xcode 14.2, and on Windows see below for the terminal to run them from).

| Command | What it does |
|---|---|
| `bun run build:ziggy-example:<platform>` | Builds the page and the app. |
| `bun run run:ziggy-example:<platform>` | Builds the app and launches it (an emulator, simulator or device for a phone). |
| `bun run open:ziggy-example:<platform>` | Syncs, then opens the native project in its editor. |
| `bun run package:ziggy-example:<platform>` | Packages the app for distribution, without the test hooks. |
| `bun run distribute:ziggy-example:android` | Builds the Android app and uploads it to Firebase App Distribution for the tester group. See `scripts/distribute-android.md`. |
| `bun run clean:ziggy-example:<platform>` | Removes the platform's build output. |
| `bun run test:ziggy-example` | The smoke tests on the host operating system. |
| `bun run test:ziggy-example:and` | The smoke tests on the Android emulator pool or a device. |
| `bun run test:ziggy-example:ios` | The smoke tests on the iOS simulator. |

`bun run package:ziggy-example:<platform>` builds the release app, without the test hooks, and writes unsigned packages. Each platform's script doc says where they go and what they need:

| Platform | Packages | Where | Script doc |
|---|---|---|---|
| `linux` | zip, `.deb` | `out/linux/` | `scripts/package-linux.md` |
| `windows` | zip, NSIS installer `.exe` | `shells/windows/package/` | `scripts/package-windows.md` |
| `macos` | `.dmg`, zip | `shells/macos/zig-out/package/` | `scripts/package-macos.md` |
| `ios` | `.xcarchive`, `.ipa` | `shells/ios/zig-out/package/` | `scripts/package-ios.md` |
| `android` | `.apk` per architecture | `release/` | `scripts/package-android.md` |

On Linux, `scripts/sync-linux.md` also says how to build just the release executable.

`bun run test` runs the page's unit tests. `bun run test:zig` runs the Zig unit tests of Ziggy's core, the example's core and the Windows shell package, and `bun run compile:zig` builds the Zig code and cross-builds it for every platform. `bun run test:everything` runs both, each as its own lane.

## What each platform needs

- **Linux:** the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0`, `libwebkit2gtk-4.1-0`) to build and run, with no development packages, `xvfb`, `xwininfo` and `jq` for the smoke tests, and `zip` and `dpkg-deb` to package. If the web view's sandbox cannot start on your system the app says so and runs without it. See `scripts/run-linux.md`.
- **Windows:** the scripts are bash scripts and run under Git Bash. The tools `mise install` puts in place (`bun`, `zig`, `jq`) must be on PATH: add `%LOCALAPPDATA%\mise\shims` to PATH, or activate mise in your shell. Then `bun run --filter=ziggy-example setup` downloads the pinned WebView2 SDK, once. Building needs Microsoft's C++ toolchain and the Windows SDK (Visual Studio or its Build Tools, the "Desktop development with C++" workload), because the WebView2 loader is linked into the exe from the SDK's static library and that library is built with it. Packaging needs NSIS (`makensis`).
- **MacOS and iOS:** a Mac with the pinned toolchain, macOS 12.7.6 and Xcode 14.2. No version is raised.
- **Android:** `bun run --filter=ziggy-example setup`, which uses the same Android SDK setup as the rest of the repository.

## Test hooks

The smoke tests drive the real app through the test hooks listed in "Test hooks" in the architecture document. They are compiled in only by the `test-hooks` build option, which the smoke test runner sets and the `package` commands never do. Scenario `8-release-has-no-hooks` checks the release build has none.

## CI

`.github/workflows/ziggy-example.yml` is a workflow of its own: it builds, tests and packages the example on Linux, Windows, macOS, iOS and Android whenever the example or anything it is built from changes, and uploads the packages as artifacts of the run. It creates no tag and no release, and the regular release workflow knows nothing about it.
