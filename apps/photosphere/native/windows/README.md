# Windows native app

The Windows desktop native app hosts the system web view and passes messages between the page and the Zig core library. It does nothing else the core can do.

## What it does

- Creates the window, with the `-geometry=WxH+X+Y` command line option and the window title.
- Injects the `window.ziggy` script before the page loads, loads the bundled page, calls `ziggy_create`, forwards page messages to `ziggy_post_message` and delivers Zig messages to the page on the UI thread.
- Blocks navigation away from the bundled page and opens external links in the system browser, asking the core's origin check whether an address is the app's own.
- Provides the application menu (content defined by the core), the native file, folder and save dialogs, drag and drop of files, the developer tools toggle and single-instance behaviour.

## Web view API

A Zig executable hosting WebView2 through its C-compatible COM interface. The injected script is registered with WebView2's add-script-on-document-created call, and messages travel through its web message API in both directions.

## Project and build

The native app is built by the `build.zig` at the root of the repository. `sync:windows` builds the core as a static library and the frontend and copies them into the project, then `zig build` builds the native app from the root of the repository. `open:windows` opens the project in the editor. Runs on Windows, and cross-compiles from Linux. See [Photosphere App](../../README.md).

## Icon and second copies

The executable carries `icons/photosphere.ico` as a resource (`photosphere.rc`), and the native app's window class loads it as `icon_resource`. The resource number is 2, not 1: Ziggy's native app casts it to a wide string pointer, which must be 2-aligned, so an odd number panics with "incorrect alignment" at startup. The native app does the `focus-window` action the core asks for when a second copy of the app was started by restoring the window if it is minimised and bringing it to the front, and flashes the taskbar button when Windows refuses the foreground.
