# Windows shell

The Windows desktop shell hosts the system web view and passes messages between the page and the Zig core library. It does nothing else the core can do.

## What it does

- Creates the window, with the `-geometry=WxH+X+Y` command line option and the window title.
- Injects the `window.ziggy` script before the page loads, loads the bundled page, calls `ziggy_create`, forwards page messages to `ziggy_post_message` and delivers Zig messages to the page on the UI thread.
- Blocks navigation away from the bundled page and opens external links in the system browser, asking the core's origin check whether an address is the app's own.
- Provides the application menu (content defined by the core), the native file, folder and save dialogs, drag and drop of files, the developer tools toggle and single-instance behaviour.

## Web view API

A Zig executable hosting WebView2 through its C-compatible COM interface. The injected script is registered with WebView2's add-script-on-document-created call, and messages travel through its web message API in both directions.

## Project and build

The shell is a Zig package with its own `build.zig` and `build.zig.zon`. `sync:windows` builds the core as a static library and the UI and copies them into the project, then `zig build` builds the shell. `open:windows` opens the project in the editor. Runs on Windows, and cross-compiles from Linux. See [Photosphere App](../../README.md).
