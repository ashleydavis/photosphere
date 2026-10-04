# MacOS shell

The MacOS desktop shell is a Swift app that hosts a `WKWebView` and passes messages between the page and the Zig core library. It does nothing else the core can do.

## What it does

- Creates the window and the application menu (content defined by the core, plus the macOS app menu), the native file, folder and save dialogs, drag and drop, the developer tools toggle and single-instance behaviour, using AppKit.
- Injects the `window.ziggy` script with a `WKUserScript`, receives page messages in a `WKScriptMessageHandler`, calls `ziggy_create` and `ziggy_post_message` through a bridging header that includes `ziggy.h`, and delivers Zig messages to the page on the main thread.
- Blocks navigation away from the bundled page and opens external links in the system browser, asking the core's origin check whether an address is the app's own.

## Project and build

An Xcode project. `sync:macos` builds the core as a static library and the UI and copies them into the project, then `xcodebuild` builds the app. `open:macos` opens the project in Xcode. Runs on MacOS only. See [Photosphere App](../../README.md).
