# Ziggy

Ziggy is the application shell: a Zig core, a native host for each platform that shows the system web view, and a small TypeScript bridge that gives the page `window.ziggy`. The UI is TypeScript in the page, and everything else is Zig. See [the architecture guide](docs/architecture.md) for how the parts fit, the message protocol, and how to add a channel, a task type or a native host callback.

All of Ziggy is in this folder, and nothing in it names an app. An app (the [Ziggy example](../../apps/ziggy-example/README.md), or Photosphere) lives under `apps/` and holds everything of its own: its page, its Zig core, and a native project for each platform. An app uses Ziggy and never another app.

## Where things are

- `core/`: the Zig library every app links. It has the C interface (`core/src/lib/ziggy.h`), the message dispatcher, the task runner, the origin check, the host callback plumbing and the test control connection. It is the same code on every platform and never touches a window.
- `bridge/`: the TypeScript the page side needs. `inject/ziggy-inject.js` is the script every shell injects to create `window.ziggy`. It is embedded in the core library, so an app supplies nothing for it. `src` holds its types.
- `native/<platform>/`: the framework half of each shell, which hosts the system web view, draws the menu, handles shortcuts and developer tools, shows the file and folder dialogs, and moves messages between the page and the core through `ziggy.h`.
  - `linux`: Zig, GTK 3 and WebKitGTK 4.1.
  - `windows`: Zig, WebView2.
  - `apple`: Swift, WKWebView. MacOS and iOS share this one package.
  - `android`: Java, the Android WebView, with the native methods implemented in the core (`core/src/lib/jni.zig`).
- `docs/`: the architecture guide.

## What an app supplies

The framework half in `native/` does the work. An app's own native project (`apps/<app>/shells/<platform>`) is small: it names the app, sets the window, and packages the app's core library and built page next to the framework half. The app's core adds its channel handlers, task handlers and menu to Ziggy's core. The example's [README](../../apps/ziggy-example/README.md) shows the whole of it.

## Running the tests

`bun run test:zig` runs the Zig tests of Ziggy, the example, the CLI and every package in `packages-zig`, all from the `build.zig` at the root of the repository, `bun run compile:zig` builds and cross-builds the Zig code, and `bun run --filter=ziggy-bridge test` runs the bridge's tests. The platform smoke tests that drive a whole app are in the example (`bun run test:ziggy-example`).
